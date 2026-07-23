#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/release-status.js"
    FACADE="$REPO/scripts/na-dev.js"
}

@test "release-status reports branch, public worktree, and github remote as json" {
    [ -x "$SCRIPT" ]
    output="$(node "$SCRIPT" --repo-root "$REPO" --json)"
    echo "$output" | grep -q '"schemaVersion":"1.0.0"'
    echo "$output" | grep -q '"repoRoot"'
    echo "$output" | grep -q '"currentBranch"'
    echo "$output" | grep -q '"publicRelease"'
    echo "$output" | grep -q '"githubRemote"'
    echo "$output" | grep -q '"privateRisk"'
}

@test "release-status ignores generated manifest changes when bundle source inputs are clean" {
    FIXTURE="$BATS_TEST_TMPDIR/release-status-clean-source"
    git clone -q --no-hardlinks "$REPO" "$FIXTURE"
    cp "$REPO/scripts/release-status.js" "$FIXTURE/scripts/release-status.js"
    cp "$REPO/scripts/lib/bundle-version.js" "$FIXTURE/scripts/lib/bundle-version.js"
    git -C "$FIXTURE" config user.email "tests@novel-assistant.local"
    git -C "$FIXTURE" config user.name "Novel Assistant Tests"
    git -C "$FIXTURE" add scripts/release-status.js scripts/lib/bundle-version.js
    if ! git -C "$FIXTURE" diff --cached --quiet; then
        git -C "$FIXTURE" commit -qm "test release status fixture"
    fi
    node "$FIXTURE/scripts/na-dev.js" bundle >/dev/null
    output="$(node "$FIXTURE/scripts/release-status.js" --repo-root "$FIXTURE" --json)"
    STATUS="$output" node - <<'NODE'
const status = JSON.parse(process.env.STATUS);
const bundle = status.bundleVersion || {};
if (!bundle.sourceTreeCurrent) throw new Error('test requires current bundle contents');
if (bundle.currentSourceState !== 'clean') {
  throw new Error(`expected clean source inputs, got ${bundle.currentSourceState}`);
}
if (bundle.releaseStatus !== 'candidate_ready') {
  throw new Error(`expected candidate_ready, got ${bundle.releaseStatus}`);
}
if (bundle.releaseReady !== true) throw new Error(`expected releaseReady=true, got ${bundle.releaseReady}`);
NODE
}

@test "na-dev exposes release-status command" {
    output="$(node "$FACADE" --help)"
    echo "$output" | grep -q "release-status"
    node "$FACADE" release-status --json | grep -q '"schemaVersion":"1.0.0"'
}

@test "script docs document release-status before publishing" {
    grep -q "release-status.js" "$REPO/scripts/README.md"
    grep -q "node scripts/na-dev.js release-status" "$REPO/scripts/README.md"
}
