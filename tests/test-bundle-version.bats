#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VERSION="$REPO/scripts/lib/bundle-version.js"
}

@test "bundle version hashes POSIX destinations by UTF-8 bytes across locales" {
    tmp="$(mktemp -d)"
    printf 'a\n' > "$tmp/a"
    printf 'z\n' > "$tmp/z"
    printf 'umlaut\n' > "$tmp/umlaut"

    node - "$VERSION" "$tmp" <<'NODE'
const { spawnSync } = require('child_process');
const versionPath = process.argv[2];
const root = process.argv[3];
const program = `
  const version = require(${JSON.stringify(versionPath)});
  const root = ${JSON.stringify(root)};
  const entries = [
    { source: root + '/z', destination: 'z' },
    { source: root + '/umlaut', destination: 'ä' },
    { source: root + '/a', destination: 'a' },
  ];
  const sorted = version.sortEntries(entries).map((entry) => entry.destination);
  process.stdout.write(JSON.stringify({ sorted, hash: version.hashEntries(entries) }));
`;
const outputs = ['C', 'sv_SE.UTF-8'].map((locale) => {
  const result = spawnSync(process.execPath, ['-e', program], {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: locale, LANG: locale },
  });
  if (result.status !== 0) process.exit(1);
  return JSON.parse(result.stdout);
});
const expected = ['a', 'z', 'ä'];
if (JSON.stringify(outputs[0].sorted) !== JSON.stringify(expected)) process.exit(2);
if (JSON.stringify(outputs[0]) !== JSON.stringify(outputs[1])) process.exit(3);
NODE

    rm -rf "$tmp"
}

@test "source layout uses an in-checkout override and refuses unsafe manifest paths" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    outside="$tmp/outside"
    mkdir -p "$repo/skills/novel-assistant" "$repo/fixtures/internal" "$repo/config"
    mkdir -p "$outside"
    cp "$REPO/skills/novel-assistant/SKILL.md" "$repo/skills/novel-assistant/SKILL.md"
    cp "$REPO/config/novel-assistant-bundle-files.json" "$repo/config/novel-assistant-bundle-files.json"
    ln -s "$REPO/scripts" "$repo/scripts"
    ln -s "$outside" "$repo/fixtures/outside-link"
    for name in story story-workflow story-memory story-long-write story-short-write story-long-analyze story-short-analyze story-long-scan story-short-scan story-deslop story-cover story-import story-review story-setup browser-cdp; do
        ln -s "$REPO/src/internal-skills/$name" "$repo/fixtures/internal/$name"
    done

    node - "$VERSION" "$repo" <<'NODE'
const version = require(process.argv[2]);
const repo = process.argv[3];
const layout = version.buildSourceLayout(repo, {
  includePrivate: false,
  sourceSkillsDir: `${repo}/fixtures/internal`,
});
const manifestLayout = version.manifestSourceLayout(repo, layout);
if (manifestLayout.sourceSkillsDir !== 'fixtures/internal') process.exit(1);
if (manifestLayout.includePrivate !== false || manifestLayout.privateSourceSkillsDir !== null) process.exit(2);
const restored = version.resolveManifestSourceLayout(repo, manifestLayout);
if (!restored) process.exit(3);
if (version.computeSourceTreeId(repo, 'novel-assistant', layout) !== version.computeSourceTreeId(repo, 'novel-assistant', restored)) process.exit(4);
if (version.resolveManifestSourceLayout(repo, { ...manifestLayout, sourceSkillsDir: '../outside' }) !== null) process.exit(5);
const unsafeLayout = version.manifestSourceLayout(repo, version.buildSourceLayout(repo, {
  includePrivate: false,
  sourceSkillsDir: `${repo}/fixtures/outside-link`,
}));
if (unsafeLayout.recomputable !== false || unsafeLayout.sourceSkillsDir !== null) process.exit(6);
if (version.resolveManifestSourceLayout(repo, unsafeLayout) !== null) process.exit(7);
NODE

    rm -rf "$tmp"
}

@test "source layout rejects repository files as source directories" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    mkdir -p "$repo/source-dir" "$repo/private-dir"
    printf 'source file\n' > "$repo/source-file"
    printf 'private source file\n' > "$repo/private-source-file"

    node - "$VERSION" "$repo" <<'NODE'
const version = require(process.argv[2]);
const repo = process.argv[3];
for (const [field, file] of [
  ['sourceSkillsDir', 'source-file'],
  ['privateSourceSkillsDir', 'private-source-file'],
]) {
  const layout = version.buildSourceLayout(repo, {
    includePrivate: true,
    ...(field === 'sourceSkillsDir'
      ? { sourceSkillsDir: `${repo}/${file}`, privateSourceSkillsDir: `${repo}/private-dir` }
      : { sourceSkillsDir: `${repo}/source-dir`, privateSourceSkillsDir: `${repo}/${file}` }),
  });
  const manifestLayout = version.manifestSourceLayout(repo, layout);
  if (manifestLayout[field] !== null || manifestLayout.recomputable !== false) process.exit(1);
  if (version.resolveManifestSourceLayout(repo, manifestLayout) !== null) process.exit(2);
  if (version.computeManifestSourceTreeId(repo, 'novel-assistant', manifestLayout) !== null) process.exit(3);
}
NODE

    rm -rf "$tmp"
}

@test "source state distinguishes clean and dirty repositories" {
    tmp="$(mktemp -d)"
    git -C "$tmp" init -q
    git -C "$tmp" config user.email fixture@example.com
    git -C "$tmp" config user.name fixture
    printf 'tracked\n' > "$tmp/tracked"
    git -C "$tmp" add tracked
    git -C "$tmp" commit -qm fixture

    node - "$VERSION" "$tmp" <<'NODE'
const version = require(process.argv[2]);
if (version.sourceState(process.argv[3]) !== 'clean') process.exit(1);
NODE
    printf 'dirty\n' > "$tmp/untracked"
    node - "$VERSION" "$tmp" <<'NODE'
const version = require(process.argv[2]);
if (version.sourceState(process.argv[3]) !== 'dirty') process.exit(1);
NODE

    rm -rf "$tmp"
}

@test "bundle build keeps clean source state across consecutive generated manifest refreshes" {
    fixture="$BATS_TEST_TMPDIR/bundle-source-state"
    git clone -q --no-hardlinks "$REPO" "$fixture"
    cp "$REPO/scripts/lib/bundle-version.js" "$fixture/scripts/lib/bundle-version.js"
    cp "$REPO/scripts/build-oh-story-bundle.sh" "$fixture/scripts/build-oh-story-bundle.sh"
    git -C "$fixture" config user.email "tests@novel-assistant.local"
    git -C "$fixture" config user.name "Novel Assistant Tests"
    git -C "$fixture" add scripts/lib/bundle-version.js scripts/build-oh-story-bundle.sh
    if ! git -C "$fixture" diff --cached --quiet; then
        git -C "$fixture" commit -qm "test clean bundle source state"
    fi

    bash "$fixture/scripts/build-oh-story-bundle.sh" >/dev/null
    bash "$fixture/scripts/build-oh-story-bundle.sh" >/dev/null
    node - "$fixture/skills/novel-assistant/novel-assistant-manifest.json" <<'NODE'
const manifest = require(process.argv[2]);
if (manifest.sourceState !== 'clean') throw new Error(`expected clean, got ${manifest.sourceState}`);
NODE
}

@test "release source state ignores non-bundle planning files but catches bundle inputs" {
    fixture="$BATS_TEST_TMPDIR/bundle-source-input-state"
    git clone -q --no-hardlinks "$REPO" "$fixture"
    git -C "$fixture" config user.email "tests@novel-assistant.local"
    git -C "$fixture" config user.name "Novel Assistant Tests"
    mkdir -p "$fixture/docs/superpowers"
    printf 'transient plan report\n' > "$fixture/docs/superpowers/local-run.md"

    node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
if (version.releaseSourceState(process.argv[3], 'novel-assistant') !== 'clean') process.exit(1);
NODE

    printf '\n// bundle input state test\n' >> "$fixture/scripts/workflow-runner.js"
    node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
if (version.releaseSourceState(process.argv[3], 'novel-assistant') !== 'dirty') process.exit(1);
NODE
}

@test "review evidence mapper participates in the source tree identity" {
    fixture="$BATS_TEST_TMPDIR/bundle-version-review-evidence"
    git clone -q --no-hardlinks "$REPO" "$fixture"

    before="$(node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
process.stdout.write(version.computeSourceTreeId(process.argv[3], 'novel-assistant'));
NODE
)"
    printf '\n// source-tree-contract-test\n' >> "$fixture/scripts/review-evidence-map.js"
    after="$(node - "$VERSION" "$fixture" <<'NODE'
const version = require(process.argv[2]);
process.stdout.write(version.computeSourceTreeId(process.argv[3], 'novel-assistant'));
NODE
)"

    [ "$before" != "$after" ]
}

@test "native POSIX helper changes require a bundle rebuild" {
    fixture="$BATS_TEST_TMPDIR/bundle-version-native-helper"
    git clone -q --no-hardlinks "$REPO" "$fixture"
    cp "$REPO/scripts/lib/bundle-version.js" "$fixture/scripts/lib/bundle-version.js"

    node "$fixture/scripts/na-dev.js" bundle >/dev/null
    before="$(node -e 'const manifest=require(process.argv[1]); process.stdout.write(manifest.sourceTreeId)' "$fixture/skills/novel-assistant/novel-assistant-manifest.json")"

    printf '\n/* source-tree-contract-test */\n' >> "$fixture/scripts/native/novel-assistant-safe-fs-posix.c"

    after="$(node - "$fixture" <<'NODE'
const version = require(`${process.argv[2]}/scripts/lib/bundle-version`);
process.stdout.write(version.computeSourceTreeId(process.argv[2], 'novel-assistant'));
NODE
)"
    [ "$before" != "$after" ]

    status="$(node "$fixture/scripts/release-status.js" --repo-root "$fixture" --json)"
    node -e '
const status = JSON.parse(process.argv[1]);
if (status.bundleVersion.releaseStatus !== "candidate_content_stale") process.exit(1);
if (status.bundleVersion.sourceTreeCurrent !== false) process.exit(2);
' "$status"
}
