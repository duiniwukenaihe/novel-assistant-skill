# Skill Directory Policy

This repository separates user installation from source maintenance.

## User-Facing Identity

User-facing identity is deliberately singular.

The product identity is `novel-assistant`. Users should see one install target and one command:

```text
/novel-assistant
```

`skills/ top level must contain only novel-assistant`. Anything else under `skills/` is treated as a policy failure.

## User Install Target

`skills/novel-assistant` is the only recommended user install target.

Users install:

```bash
npx skills add https://github.com/duiniwukenaihe/novel-assistant-skill.git --path skills/novel-assistant -y -g
```

Users call:

```text
/novel-assistant
```

They should not install or call `story-*`, `story`, or `browser-cdp` as parallel skills.

## Source Modules

Canonical source modules live under `src/internal-skills/`.

Examples:

- `src/internal-skills/story`
- `src/internal-skills/story-workflow`
- `src/internal-skills/story-long-write`
- `src/internal-skills/story-review`
- `src/internal-skills/story-long-analyze`
- `src/internal-skills/story-setup`
- `src/internal-skills/browser-cdp`

These modules are source code, not user-facing install packages. They are consumed by `scripts/build-oh-story-bundle.sh` to generate:

```text
skills/novel-assistant/references/internal-skills/
```

Do not edit generated internal copies directly unless the change is intentionally temporary. The next bundle build can overwrite generated copies.

## Upstream Absorption Targeting

`scripts/check-upstream.sh` reports `Novel Assistant Backport Target Mapping`.

When upstream changes a file such as:

```text
skills/story-long-write/SKILL.md
```

the report maps it to:

```text
Current canonical source target: src/internal-skills/story-long-write/SKILL.md
Generated install target: skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md
```

The safe flow is:

```text
upstream changed file
-> read Novel Assistant Backport Target Mapping
-> edit Current canonical source target under src/internal-skills/
-> run build-oh-story-bundle.sh
-> verify generated skills/novel-assistant/references/internal-skills copy
```

## Removal Rules

| Directory | Action |
|---|---|
| `skills/novel-assistant` | Keep. This is the only install package. |
| `src/internal-skills/story-*` | Keep. These are canonical source modules. |
| `src/internal-skills/story` | Keep. This is the internal router source module. |
| `src/internal-skills/browser-cdp` | Keep if browser data collection remains bundled. |
| `skills/oh-story` | Removed from this repo layout. Rebuilds must not recreate it. |
| `skills/story-*`, `skills/story`, `skills/browser-cdp` | Removed from top-level `skills/`. Rebuilds must not recreate them. |

## Maintainer Checks

Before moving, deleting, or adding any skill directory, run:

```bash
node scripts/na-dev.js skill-policy --json
```

The check fails if:

- `skills/` contains anything except `novel-assistant`
- any expected internal source module is missing from `src/internal-skills/`
- docs no longer explain the install/source split

## Maintainer Rule

README, install docs, and user-facing prompts should mention only `/novel-assistant`.

Repository internals may still mention source module names when explaining ownership, tests, bundle generation, and upstream absorption.
