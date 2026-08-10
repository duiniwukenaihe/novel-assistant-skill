# GitHub Public Release

This repository has two different publication surfaces:

- `main`: internal development branch. It may keep private planning docs, local benchmark evidence, and internal GitLab install defaults.
- `github/public-release`: sanitized GitHub branch. It must not include private planning docs, local source texts, personal writing assets, Claude transcripts, temporary benchmark runs, internal LAN URLs, local machine paths, or secrets.

The public GitHub repository is:

```text
https://github.com/duiniwukenaihe/novel-assistant-skill
```

The product and skill command remain:

```text
novel-assistant
/novel-assistant
```

## Release Flow

Recommended: from `main`, let the release script create an isolated sanitized branch:

```bash
node scripts/na-dev.js publish-public --source-ref main \
  --run-public-behavior-eval --max-behavior-budget-usd 10 \
  --commit --push
```

The script uses two isolated git worktrees, so `main` keeps the internal development tree and the public branch keeps its own clean ancestry. It will:

1. check out `main` as a detached source worktree,
2. sanitize and rebuild that source snapshot with `NOVEL_ASSISTANT_INCLUDE_PRIVATE=0`,
3. check out the existing `github/public-release` branch as the target worktree,
4. replace its files with the sanitized snapshot while preserving its `.git` ancestry,
5. run `public-release-audit.js` and public runtime verification again on the target,
6. run `git diff --check`,
7. optionally commit and push when `--commit --push` are passed.

The paid behavior collection flag is explicit by design. It runs all six public release scenarios against Claude, Codex, and ZCode with the declared per-scenario budget ceiling. Without either that flag or already-valid external evidence, the production gate blocks commit/push; it never treats an empty report directory as a pass.

The publisher must never create the public branch with `switch -C` from `main`: deleting private files from the final tree does not remove them from inherited Git history. An existing clean public-history baseline is therefore required.

The script refuses to commit or push if any verification step fails.

## Public File And Version Policy

`config/github-public-release-files.json` is the explicit public-release policy. The existing `github/public-release` Git index is the baseline whitelist; policy fields control changes to that baseline:

- `additionalFiles` authorizes new public files. A listed file that is missing from the sanitized source blocks the release.
- `removedFiles` revokes an already published path even when the file remains on private `main`.
- `releaseVersion` is the public version source. It must match the version shown in `README.md`, the first version in the sanitized `CHANGELOG.md`, and `skills/novel-assistant/novel-assistant-manifest.json`.

Files outside the baseline and `additionalFiles` are skipped and reported; they are never copied by default. A path cannot appear in both `additionalFiles` and `removedFiles`.

The sanitizer removes public-only forbidden assets:

- `docs/superpowers/`
- `reports/upstream/`
- `src/private-internal-skills/`
- `skills/novel-assistant/references/private-internal-skills/`
- private maintainer-only sync scripts
- maintainer-only public-release and local-extension coverage fixtures
- `benchmarks/`
- personal `demo/` assets
- original source text files under `demo/**/原文/原文.txt`
- original source text files under `benchmarks/**/原文/原文.txt`
- benchmark `input/原文.txt`
- Claude run logs such as `claude-run.jsonl`
- benchmark prompts such as `prompt.txt`
- personal full novel drafts under `demo/**/正文/`
- private cover images or binary demo assets

It intentionally keeps the public workflow orchestration:

- `src/internal-skills/story-workflow/`
- `skills/novel-assistant/references/internal-skills/story-workflow/`
- `scripts/workflow-state-machine.js`
- public workflow/runtime scripts bundled by `build-oh-story-bundle.sh`

Private workflow owners and overlays live under private skill directories, so they are removed with the private assets.

After sanitization, public workflow behavior must be:

- `workflow-state-machine.js templates --json` reports `privateRegistryCount=0`.
- `short_write` control stages route to public `story-workflow`; professional short-form stages route to public `story-short-write`.
- no private short-form startup workflow is visible.
- no private download/import owner is visible.

## Runtime Verification Before Push

`publish-public` validates the generated GitHub branch before commit/push:

- `public-release-audit.js --json` must pass.
- `production-smoke-matrix.js --json` must pass on the sanitized worktree.
- `bats tests/test-workflow-v3-new-short-e2e.bats` must complete the public V3 short-writing production loop.
- `workflow-state-machine.js templates --json` must report `privateRegistryCount=0`.
- `short_write` may use `story-workflow` for control stages; every professional short-form stage must use public `story-short-write`.
- `private_short_startup` must not exist in public templates.
- `skills/novel-assistant/novel-assistant-manifest.json` must use the GitHub update source.
- `privateInternalSkillCount` must be `0`.
- public entry/router/workflow/short-write bundle files must exist.
- the exact sanitized bundle must have six paid, hash-bound public behavior reports with passing Claude and ZCode host results; the separate install gate still verifies Claude/Codex/ZCode mirrors.
- paid evaluation copies that exact candidate into the disposable project-local host skill roots, so it cannot silently evaluate a user's global private installation.
- the three installed mirrors must load the expected public runtime registry; matching files alone is insufficient.
- `git diff --check` must pass.

`--skip-runtime-verify` is available only for an uncommitted diagnostic preview. The publisher rejects it together with `--commit` or `--push`, so production artifacts cannot bypass smoke, E2E, registry, or owner gates.

This is deliberately stricter than “clean enough to push”: the GitHub branch must be installable and routable as a public `novel-assistant` package.

The sanitizer also rewrites public text files in the worktree:

- internal LAN install URLs become `https://github.com/duiniwukenaihe/novel-assistant-skill.git`,
- local machine paths are replaced with placeholders,
- private feature names are replaced with generic extension wording.

Manual fallback if you are already on `github/public-release`:

```bash
node scripts/na-dev.js prepare-public
```

`prepare-public` rebuilds `skills/novel-assistant` with:

```text
https://github.com/duiniwukenaihe/novel-assistant-skill.git
```

and then runs `public-release-audit.js`.

## Why This Lives On Main

The release tooling belongs on `main` because release is a recurring activity. The sanitized branch should be produced by repeatable scripts, not memory.

The sanitized deletions do **not** belong on `main`. Main remains the working branch for internal development, private short-form assets, private download assets, and upstream absorption. Only the GitHub branch needs to be clean.

## Public Audit Rules

`scripts/public-release-audit.js` fails when tracked files contain:

- internal LAN Git remotes or hosts
- local user paths
- server workspace paths
- example passwords copied from support sessions
- private Superpowers planning docs
- private internal skill assets under `src/private-internal-skills/` or `skills/novel-assistant/references/private-internal-skills/`
- demo text assets
- raw source text
- personal demo chapters
- benchmark prompt/transcript files
- demo binary image assets

The audit also requires:

```text
skills/novel-assistant/novel-assistant-manifest.json
```

to use the public GitHub update source.

## Push

After verification:

```bash
git push github github/public-release
git push origin github/public-release
```

## Stable Tag And Install Artifact

Create the stable tag only from the verified public commit, never from private `main`:

```bash
git -C .worktrees/github-public-release tag -a vX.Y.Z -m "发布 novel-assistant vX.Y.Z"
git -C .worktrees/github-public-release push github vX.Y.Z
```

The tag is an immutable public candidate, not an automatic packaging trigger. First dispatch **Collect public behavior evidence** (`.github/workflows/github-behavior-evidence.yml`) on the exact tag commit from the protected `novel-assistant-eval` self-hosted runner. It performs the explicit paid six-scenario/three-host matrix and uploads a hash-bound artifact named for that exact commit.

Then dispatch **Publish GitHub release artifact** with the tag and the successful evidence workflow run ID. The release workflow downloads only that artifact, rechecks its bundle ID, paid status, host usage, assertion-evidence hashes, public audit, smoke matrix, runtime registry, and three isolated install mirrors before it creates:

```text
novel-assistant-vX.Y.Z.tar.gz
novel-assistant-vX.Y.Z.tar.gz.sha256
```

The archive is built reproducibly from the tag's `skills/novel-assistant` subtree. It contains the installable single-directory public runtime, not the repository source tree. A missing or mismatched evidence artifact, failed audit, smoke case, ownership check, tag/changelog mismatch, or artifact build stops the release.
