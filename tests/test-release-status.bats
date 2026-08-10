#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/release-status.js"
    FACADE="$REPO/scripts/na-dev.js"
}

@test "release-status reports branch, public worktree, and github remote as json" {
    [ -x "$SCRIPT" ]
    run node "$SCRIPT" --repo-root "$REPO" --json
    [ "$status" -eq 2 ]
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
    run node "$FIXTURE/scripts/release-status.js" --repo-root "$FIXTURE" --verify-bundle --json
    [ "$status" -eq 2 ]
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

@test "release-status rejects a pass receipt whose tree or source-input digest is stale" {
    FIXTURE="$BATS_TEST_TMPDIR/release-status-stale-receipt"
    receipt="$FIXTURE/reports/private/production-repair/latest/production-release-gate.json"
    mkdir -p "$(dirname "$receipt")"
    cat > "$receipt" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "status": "pass",
  "release_ready": true,
  "profile": "local-private",
  "repoRoot": "/fixture",
  "required": ["deterministic_core", "behavior_eval", "bundle_current", "public_tree_audit", "public_behavior_eval", "install_consistency"],
  "gates": [
    {"id":"deterministic_core","status":"pass"}, {"id":"behavior_eval","status":"pass"},
    {"id":"bundle_current","status":"pass"}, {"id":"public_tree_audit","status":"pass"},
    {"id":"public_behavior_eval","status":"pass"}, {"id":"install_consistency","status":"pass"}
  ],
  "bundle": {"bundleId":"same-bundle","sourceTreeId":"old-tree","sourceInputDigest":"old-input"}
}
JSON

    run node - "$SCRIPT" "$FIXTURE" <<'NODE'
const status = require(process.argv[2]);
const result = status.productionReleaseInfo(process.argv[3], {
  sourceState: 'clean', currentSourceState: 'clean', bundleId: 'same-bundle',
  sourceTreeId: 'current-tree', sourceInputDigest: 'current-input',
});
if (result.status !== 'blocked' || result.reason !== 'production_release_receipt_stale') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}
