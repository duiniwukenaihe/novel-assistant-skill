# Installation And Update

This guide is for normal users who only want to install and use `novel-assistant`, and for maintainers who need to understand the two update layers.

## Install Globally

Recommended:

```bash
npx skills add https://github.com/duiniwukenaihe/novel-assistant-skill.git --path skills/novel-assistant -y -g
```

`-g` installs the skill globally so every book project can call:

```text
/novel-assistant
```

## Install For One Project

Run inside the target project root and omit `-g`:

```bash
npx skills add https://github.com/duiniwukenaihe/novel-assistant-skill.git --path skills/novel-assistant -y
```

Use this only when a project needs an isolated skill copy.

## What Users Should Call

Only call:

```text
/novel-assistant
```

Do not call internal commands such as `/story-long-write`, `/story-review`, `/story-long-analyze`, or `/story-setup`. They are internal modules bundled under `novel-assistant/references/internal-skills/`.

## Skill Update

Normal update path:

```text
/novel-assistant 更新 skill
```

The skill checks its own `novel-assistant-manifest.json`, update source, current installed bundle, stable tag, and development branch.

不要使用 npx skills update as the normal update path. `npx skills add ...` is for first install or recovery from a broken install.

## Stable And Development Channels

`novel-assistant` separates stable and development updates:

- **稳定版**: recommended when a project tag/release exists and tests pass.
- **开发版**: allowed when the remote branch has useful new commits but no stable tag yet; the user must confirm because writing workflows may change.

If the local source repository is dirty, self-update refuses to overwrite it.

## Writing Collaboration Environment Update

Updating the skill package does not automatically update a book project. Each book project has deployed collaboration files:

- `.story-deployed`
- `.claude/hooks/`
- `.claude/agents/`
- `.claude/rules/`
- scripts and references copied by setup

Refresh them with:

```text
/novel-assistant 更新写作协作环境
```

This updates hooks / agents / rules / scripts / references. It does not rewrite正文、大纲、细纲. If directory layout migration is needed, the skill must ask separately.

## Startup Gate

When `/novel-assistant` starts in a book project, it first compares the installed skill bundle with `.story-deployed`.

If the writing collaboration environment is stale, the first screen must ask whether to refresh it. Before the user confirms or declines, the skill must not read current chapter state, workflow tasks, or produce writing candidates.

## Provider Profiles And Custom Endpoints

`novel-assistant` does not manage model credentials. 这不是让 skill 管理 API key、base URL、login state、billing or provider secrets. Claude Code / Codex / OpenCode or the frontend runner owns provider configuration and model selection.

The skill only uses a `provider profile` as a runtime capability note so Claude, OpenAI, Qwen, Minimax, DeepSeek, and a custom endpoint can be described consistently for workflow routing and recovery.

Supported profile concepts:

- **OpenAI-compatible endpoint**: a provider or proxy that exposes OpenAI-style chat/completions APIs. Use this for many Qwen, Minimax, DeepSeek, local gateway, or hosted custom models.
- **custom endpoint**: any private gateway that is not known by the skill yet. Before long tasks, provide or infer model name, context window, cost tier, and recommended use.
- **model_class**: `cheap_extract`, `standard_reasoning`, `deep_reasoning`, `long_context_review`, or `creative_draft`.

Recommended usage:

- Use cheaper or script-first routes for inventory, chapter counts, schema validation, filename migration, and batch extraction.
- Use stronger reasoning for outline arbitration, whole-book consistency, major rewrite impact analysis, and final review.
- After changing provider settings, run `/novel-assistant 更新写作协作环境` only if hooks/agents/scripts changed. Changing only API keys or backend provider config does not rewrite book content.
- If a provider returns safety errors such as `output new_sensitive`, do not retry the same prompt unchanged. Let workflow shrink scope or switch model_class.

The canonical skill-side contract is `src/internal-skills/story-workflow/references/model-provider-profiles.md`.

## Maintainer Source Workflow

Maintainers editing source modules run:

```bash
bash scripts/build-oh-story-bundle.sh
```

This refreshes:

- `skills/novel-assistant`

Then run:

```bash
node scripts/production-smoke-matrix.js --repo-root . --json
node scripts/maintainability-audit.js --repo-root . --json
bash scripts/run-bats-tests.sh
bash scripts/static-check.sh
git diff --check
```

Normal users do not run these maintainer commands.
