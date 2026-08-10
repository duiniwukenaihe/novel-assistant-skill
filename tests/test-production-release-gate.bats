#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GATE="$REPO/scripts/production-release-gate.js"
    STATUS="$REPO/scripts/release-status.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "production release gate requires every declared gate to pass" {
    run node - "$GATE" <<'NODE'
const gate = require(process.argv[2]);
const gates = gate.REQUIRED_GATES.map((id) => ({ id, status: 'pass', findings: [] }));
const result = gate.aggregateGateResults(gates, { profile: 'local-private' });
if (result.status !== 'pass' || result.release_ready !== true) {
  throw new Error(`expected pass, got ${JSON.stringify(result)}`);
}
NODE

    [ "$status" -eq 0 ]
}

@test "candidate-ready bundle with blocked behavior evidence is not production-ready" {
    run node - "$GATE" <<'NODE'
const gate = require(process.argv[2]);
const gates = gate.REQUIRED_GATES.map((id) => ({ id, status: id === 'behavior_eval' ? 'blocked' : 'pass', findings: [] }));
const result = gate.aggregateGateResults(gates, { profile: 'local-private' });
if (result.status !== 'blocked') throw new Error(`expected blocked, got ${result.status}`);
if (result.release_ready !== false) throw new Error('blocked gate must set release_ready=false');
if (!result.blockers.includes('behavior_eval')) throw new Error('behavior_eval is missing from blockers');
NODE

    [ "$status" -eq 0 ]
}

@test "production release gate rejects duplicate gate ids instead of letting the last result win" {
    run node - "$GATE" <<'NODE'
const gate = require(process.argv[2]);
const gates = gate.REQUIRED_GATES.map((id) => ({ id, status: 'pass', findings: [] }));
gates.push({ id: 'behavior_eval', status: 'blocked', findings: [{ id: 'forged_pass_preceded' }] });
const result = gate.aggregateGateResults(gates, { profile: 'local-private' });
if (result.status !== 'blocked' || result.release_ready !== false) throw new Error(JSON.stringify(result));
if (!result.duplicates.includes('behavior_eval')) throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}

@test "local-private release requires a distinct sanitized public candidate root" {
    run node - "$GATE" "$TMP_DIR/private-source" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.resolveReleaseRoots(process.argv[3], 'local-private', {});
if (result.ok !== false || result.reason !== 'missing_public_candidate_root') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "local-private release rejects a public-root symlink back to its private source" {
    PRIVATE="$TMP_DIR/private-source"
    ALIAS="$TMP_DIR/public-alias"
    mkdir -p "$PRIVATE"
    ln -s "$PRIVATE" "$ALIAS"

    run node - "$GATE" "$PRIVATE" "$ALIAS" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.resolveReleaseRoots(process.argv[3], 'local-private', { publicRoot: process.argv[4] });
if (result.ok !== false || result.reason !== 'public_candidate_root_must_differ_from_private_source') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "public release accepts an equivalent public-root symlink only after canonical comparison" {
    CANDIDATE="$TMP_DIR/public-candidate"
    ALIAS="$TMP_DIR/public-alias"
    mkdir -p "$CANDIDATE"
    ln -s "$CANDIDATE" "$ALIAS"

    run node - "$GATE" "$CANDIDATE" "$ALIAS" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.resolveReleaseRoots(process.argv[3], 'public', { publicRoot: process.argv[4] });
if (result.ok !== true || result.privateRoot !== result.publicRoot) throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}

@test "public release rejects evidence and receipt paths inside the candidate tree" {
    FIXTURE="$TMP_DIR/public-candidate"
    mkdir -p "$FIXTURE/reports"

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const root = process.argv[3];
const result = gate.validateReleasePaths(root, 'public', {
  evidenceRoot: `${root}/reports`,
  publicEvidenceRoot: `${root}/reports`,
  receiptOut: `${root}/reports/receipt.json`,
});
if (result.ok !== false) throw new Error(JSON.stringify(result));
const reasons = result.findings.map((item) => item.id).sort();
for (const expected of ['public_evidence_root_inside_candidate', 'receipt_out_inside_public_candidate', 'evidence_root_inside_public_candidate']) {
  if (!reasons.includes(expected)) throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "local-private release also rejects paths that would mutate its public candidate" {
    PRIVATE="$TMP_DIR/private-source"
    PUBLIC="$TMP_DIR/public-candidate"
    mkdir -p "$PRIVATE" "$PUBLIC/reports"

    run node - "$GATE" "$PRIVATE" "$PUBLIC" <<'NODE'
const gate = require(process.argv[2]);
const privateRoot = process.argv[3];
const publicRoot = process.argv[4];
const result = gate.validateReleasePaths(privateRoot, 'local-private', {
  publicRoot,
  evidenceRoot: `${publicRoot}/reports/private-evidence`,
  publicEvidenceRoot: `${publicRoot}/reports/public-evidence`,
  receiptOut: `${publicRoot}/reports/receipt.json`,
});
if (result.ok !== false) throw new Error(JSON.stringify(result));
const ids = result.findings.map((finding) => finding.id);
for (const expected of ['evidence_root_inside_public_candidate', 'public_evidence_root_inside_candidate', 'receipt_out_inside_public_candidate']) {
  if (!ids.includes(expected)) throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "a rejected public invocation never writes its error receipt into the candidate tree" {
    CANDIDATE="$TMP_DIR/public-no-evidence"
    mkdir -p "$CANDIDATE"

    run node "$GATE" --repo-root "$CANDIDATE" --profile public --json

    [ "$status" -eq 2 ]
    [ ! -e "$CANDIDATE/reports/private/production-repair/latest/production-release-gate.json" ]
}

@test "a public-root mismatch never writes its error receipt into the repo-root candidate" {
    CANDIDATE="$TMP_DIR/public-root-mismatch"
    OTHER="$TMP_DIR/other-public-root"
    mkdir -p "$CANDIDATE" "$OTHER"

    run node "$GATE" --repo-root "$CANDIDATE" --profile public --public-root "$OTHER" --evidence-root "$CANDIDATE/reports" --public-evidence-root "$TMP_DIR/external-evidence" --json

    [ "$status" -eq 2 ]
    [ ! -e "$CANDIDATE/reports/private/production-repair/latest/production-release-gate.json" ]
}

@test "a symlinked external evidence path cannot resolve back into the public candidate" {
    CANDIDATE="$TMP_DIR/public-symlink-candidate"
    LINK="$TMP_DIR/external-evidence-link"
    mkdir -p "$CANDIDATE"
    ln -s "$CANDIDATE" "$LINK"

    run node "$GATE" --repo-root "$CANDIDATE" --profile public --evidence-root "$LINK/reports" --public-evidence-root "$TMP_DIR/actual-external-evidence" --json

    [ "$status" -eq 2 ]
    [ ! -e "$CANDIDATE/reports/private/production-repair/latest/production-release-gate.json" ]
}

@test "deterministic gate consumes a current receipt without rerunning the matrix" {
    FIXTURE="$TMP_DIR/receipt-repo"
    mkdir -p "$FIXTURE/skills/novel-assistant" "$FIXTURE/reports/private/production-repair/run-1/deterministic" "$FIXTURE/scripts"
    cat > "$FIXTURE/skills/novel-assistant/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"candidate-bundle","sourceCommit":"candidate-commit"}
JSON
    cat > "$FIXTURE/reports/private/production-repair/run-1/deterministic/summary.json" <<'JSON'
{"status":"pass","exitCode":0,"bundleId":"candidate-bundle","sourceCommit":"candidate-commit","testGroups":["p0"]}
JSON
    cat > "$FIXTURE/scripts/production-smoke-matrix.js" <<'NODE'
process.exit(79);
NODE

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gateDeterministicCore(process.argv[3]);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}

@test "deterministic gate accepts evidence stored outside the candidate tree" {
    FIXTURE="$TMP_DIR/candidate-repo"
    EVIDENCE="$TMP_DIR/evidence-root"
    mkdir -p "$FIXTURE/skills/novel-assistant" "$EVIDENCE/private/production-repair/run-1/deterministic"
    cat > "$FIXTURE/skills/novel-assistant/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"candidate-bundle","sourceCommit":"candidate-commit"}
JSON
    cat > "$EVIDENCE/private/production-repair/run-1/deterministic/summary.json" <<'JSON'
{"status":"pass","exitCode":0,"bundleId":"candidate-bundle","sourceCommit":"candidate-commit","testGroups":["p0"]}
JSON

    run node - "$GATE" "$FIXTURE" "$EVIDENCE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gateDeterministicCore(process.argv[3], { evidenceRoot: process.argv[4] });
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}

@test "behavior gate exposes scenario failures instead of anonymous findings" {
    FIXTURE="$TMP_DIR/behavior-repo"
    mkdir -p "$FIXTURE/scripts"
    cat > "$FIXTURE/scripts/behavior-eval-release-gate.js" <<'NODE'
process.stdout.write(JSON.stringify({
  status: 'blocked',
  findings: [{ scenario: 'review-1-200', findings: ['missing_host:claude'], file: 'reports/behavior-eval/run/summary.json' }],
}));
process.exit(1);
NODE

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gateBehaviorEval(process.argv[3], 'local-private');
if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
const finding = result.findings[0] || {};
if (finding.id !== 'behavior_eval_scenario_failed' || finding.scenario !== 'review-1-200') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "public behavior gate delegates to the strict public candidate gate instead of trusting summaries" {
    CANDIDATE="$TMP_DIR/public-candidate"
    EVIDENCE="$TMP_DIR/public-evidence"
    mkdir -p "$CANDIDATE/scripts" "$CANDIDATE/skills/novel-assistant" "$EVIDENCE/public-behavior-eval/weak-pass"
    cat > "$CANDIDATE/skills/novel-assistant/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"public-candidate"}
JSON
    cat > "$CANDIDATE/scripts/behavior-eval-release-gate.js" <<'NODE'
process.stdout.write(JSON.stringify({
  status: 'blocked',
  findings: [{ scenario: 'route-single-entry', findings: ['not_paid_execution', 'missing_host:codex'], file: 'behavior-eval/weak-pass/summary.json' }],
}));
process.exit(1);
NODE
    cat > "$EVIDENCE/public-behavior-eval/weak-pass/summary.json" <<'JSON'
{"status":"pass","scenario":{"id":"route-single-entry"},"hosts":["claude"]}
JSON

    run node - "$GATE" "$CANDIDATE" "$EVIDENCE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gatePublicBehaviorEval(process.argv[3], { evidenceRoot: process.argv[4], publicEvidenceRoot: process.argv[4] });
if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
const finding = result.findings[0] || {};
if (finding.id !== 'public_behavior_eval_scenario_failed' || finding.scenario !== 'route-single-entry') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "public tree gate blocks a clean audit without an exact candidate manifest" {
    FIXTURE="$TMP_DIR/public-tree"
    mkdir -p "$FIXTURE/scripts"
    cat > "$FIXTURE/scripts/public-release-audit.js" <<'NODE'
process.stdout.write(JSON.stringify({ status: 'pass', findings: [] }));
NODE

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gatePublicTreeAudit(process.argv[3]);
if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
if (!result.findings.some((finding) => finding.id === 'missing_public_candidate_manifest')) {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "public tree gate rejects a candidate manifest when a listed file changes" {
    FIXTURE="$TMP_DIR/public-candidate"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/config"
    cat > "$FIXTURE/scripts/public-release-audit.js" <<'NODE'
process.stdout.write(JSON.stringify({ status: 'pass', findings: [] }));
NODE
    node - "$FIXTURE" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const relative = 'scripts/public-release-audit.js';
const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, relative))).digest('hex');
fs.writeFileSync(path.join(root, 'config/github-public-release-candidate-manifest.json'), JSON.stringify({
  schemaVersion: '1.0.0',
  files: { [relative]: digest },
}));
NODE

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gatePublicTreeAudit(process.argv[3]);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
NODE
    [ "$status" -eq 0 ]

    printf '\n// changed\n' >> "$FIXTURE/scripts/public-release-audit.js"
    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gatePublicTreeAudit(process.argv[3]);
if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
if (!result.findings.some((finding) => finding.id === 'public_candidate_digest_mismatch')) {
  throw new Error(JSON.stringify(result));
}
NODE
    [ "$status" -eq 0 ]
}

@test "public tree gate blocks a candidate symlink not covered by the exact manifest" {
    FIXTURE="$TMP_DIR/public-candidate-symlink"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/config"
    cat > "$FIXTURE/scripts/public-release-audit.js" <<'NODE'
process.stdout.write(JSON.stringify({ status: 'pass', findings: [] }));
NODE
    node - "$FIXTURE" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const relative = 'scripts/public-release-audit.js';
const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, relative))).digest('hex');
fs.writeFileSync(path.join(root, 'config/github-public-release-candidate-manifest.json'), JSON.stringify({
  schemaVersion: '1.0.0',
  files: { [relative]: digest },
}));
fs.symlinkSync('/tmp', path.join(root, 'scripts/unlisted-link'));
NODE

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gatePublicTreeAudit(process.argv[3]);
if (result.status !== 'blocked') throw new Error(JSON.stringify(result));
if (!result.findings.some((finding) => finding.id === 'public_candidate_symlink' && finding.target === 'scripts/unlisted-link')) {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "release status is non-zero whenever its production gate is blocked" {
    run node "$STATUS" --repo-root "$REPO" --json

    [ "$status" -eq 2 ]
    echo "$output" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (!data.productionRelease || data.productionRelease.status === "pass") {
  throw new Error("release-status did not surface a blocked production gate");
}
'
}

@test "release status reads a production receipt instead of rerunning release checks" {
    grep -q 'readProductionReleaseReceipt' "$REPO/scripts/release-status.js"
    ! grep -q "evaluateGate(repoRoot, 'local-private')" "$REPO/scripts/release-status.js"
}

@test "explicit production gate evaluation persists the authoritative latest receipt" {
    FIXTURE="$TMP_DIR/receipt-persistence"
    mkdir -p "$FIXTURE"

    run node "$GATE" --repo-root "$FIXTURE" --json

    [ "$status" -eq 1 ]
    receipt="$FIXTURE/reports/private/production-repair/latest/production-release-gate.json"
    [ -f "$receipt" ]
    node - "$receipt" <<'NODE'
const receipt = require(process.argv[2]);
if (receipt.status !== 'blocked' || receipt.release_ready !== false) throw new Error(JSON.stringify(receipt));
NODE
}

@test "release status rejects a forged pass receipt without every required passing gate" {
    FIXTURE="$TMP_DIR/forged-receipt"
    receipt="$FIXTURE/reports/private/production-repair/latest/production-release-gate.json"
    mkdir -p "$(dirname "$receipt")"
    cat > "$receipt" <<'JSON'
{"schemaVersion":"1.0.0","status":"pass","release_ready":true,"bundle":{"bundleId":"forged"}}
JSON

    run node - "$GATE" "$FIXTURE" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.readProductionReleaseReceipt(process.argv[3]);
if (result.status !== 'blocked' || result.reason !== 'invalid_production_release_receipt') {
  throw new Error(JSON.stringify(result));
}
NODE

    [ "$status" -eq 0 ]
}

@test "default release status keeps bundle content verification opt-in" {
    run node - "$REPO/scripts/release-status.js" <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
if (!source.includes('--verify-bundle')) throw new Error('missing explicit bundle verification option');
if (source.includes('bundleVersion(resolvedRoot);')) throw new Error('default status still computes bundle content identity');
NODE
    [ "$status" -eq 0 ]
}

@test "publish-github-public-branch uses the target branch for self-update" {
    grep -q 'NOVEL_ASSISTANT_UPDATE_BRANCH="$TARGET_BRANCH"' "$REPO/scripts/publish-github-public-branch.sh"
}

@test "public publisher and GitHub release workflow call the unified production gate" {
    grep -q 'production-release-gate.js' "$REPO/scripts/publish-github-public-branch.sh"
    grep -q 'production-release-gate.js' "$REPO/.github/workflows/github-release.yml"
    grep -q -- '--receipt-out' "$REPO/.github/workflows/github-release.yml"
    grep -q -- '--install-root "$PUBLIC_INSTALL_HOME"' "$REPO/.github/workflows/github-release.yml"
    grep -q -- '--public-evidence-root "$PUBLIC_EVIDENCE_ROOT"' "$REPO/.github/workflows/github-release.yml"
}

@test "public publisher produces deterministic evidence before the unified gate" {
    smoke_line="$(grep -n 'production-smoke-matrix.js.*--receipt-out' "$REPO/scripts/publish-github-public-branch.sh" | head -n 1 | cut -d: -f1)"
    gate_line="$(grep -n 'production-release-gate.js' "$REPO/scripts/publish-github-public-branch.sh" | head -n 1 | cut -d: -f1)"
    [ -n "$smoke_line" ]
    [ -n "$gate_line" ]
    [ "$smoke_line" -lt "$gate_line" ]
    grep -q -- '--evidence-root "$EVIDENCE_ROOT"' "$REPO/scripts/publish-github-public-branch.sh"
    grep -q -- '--public-evidence-root "$PUBLIC_EVIDENCE_ROOT"' "$REPO/scripts/publish-github-public-branch.sh"
    grep -q -- '--install-root "$PUBLIC_INSTALL_HOME"' "$REPO/scripts/publish-github-public-branch.sh"
}

@test "public publisher has an explicit paid evidence collection path instead of silently skipping it" {
    script="$REPO/scripts/publish-github-public-branch.sh"
    grep -q -- '--run-public-behavior-eval' "$script"
    grep -q -- '--max-behavior-budget-usd' "$script"
    grep -A6 'behavior-eval.js' "$script" | grep -q -- '--execute-paid'
}

@test "public publisher runs paid evidence from the sanitized public worktree" {
    script="$REPO/scripts/publish-github-public-branch.sh"
    grep -A18 'RUN_PUBLIC_BEHAVIOR_EVAL' "$script" | grep -q 'cd "$WORKTREE_DIR"'
}

@test "public publisher defaults paid behavior evidence to Claude and ZCode" {
    script="$REPO/scripts/publish-github-public-branch.sh"
    grep -q '^BEHAVIOR_HOSTS="claude,zcode"$' "$script"
    grep -q 'default: claude,zcode' "$script"
}

@test "public publisher passes the exact public candidate skill to paid evaluation" {
    script="$REPO/scripts/publish-github-public-branch.sh"
    grep -A16 'node scripts/behavior-eval.js run' "$script" | grep -q -- '--skill-dir "$WORKTREE_DIR/skills/novel-assistant"'
}

@test "GitHub release consumes a hash-bound public behavior evidence artifact" {
    workflow="$REPO/.github/workflows/github-release.yml"
    evidence_workflow="$REPO/.github/workflows/github-behavior-evidence.yml"
    grep -q 'behavior_evidence_run_id' "$workflow"
    grep -q 'actions/download-artifact@v4' "$workflow"
    grep -q 'novel-assistant-behavior-evidence-' "$workflow"
    [ -f "$evidence_workflow" ]
    grep -q 'self-hosted' "$evidence_workflow"
    grep -q 'behavior-eval-release-gate.js' "$evidence_workflow"
    grep -q 'actions/upload-artifact@v4' "$evidence_workflow"
    grep -q 'id: candidate' "$workflow"
    grep -q 'id: candidate' "$evidence_workflow"
    grep -q 'steps.candidate.outputs.commit' "$workflow"
    grep -q 'steps.candidate.outputs.commit' "$evidence_workflow"
    ! grep -q 'github.sha' "$evidence_workflow"
}

@test "release documentation names the unified production gate" {
    grep -q 'production-release-gate.js' "$REPO/scripts/README.md"
    grep -q 'node scripts/na-dev.js release-status' "$REPO/scripts/README.md"
}

@test "self-update and local private install import the shared target resolver" {
    grep -q 'install-target-resolver' "$REPO/scripts/novel-assistant-self-update.js"
    grep -q 'install-target-resolver' "$REPO/scripts/na-dev.js"
}

@test "install target resolver keeps Claude Codex and ZCode required while OpenCode is opt-in" {
    run node - "$REPO/scripts/lib/install-target-resolver.js" <<'NODE'
const resolver = require(process.argv[2]);
const required = resolver.requiredHosts().sort();
if (JSON.stringify(required) !== JSON.stringify(['claude', 'codex', 'zcode'])) {
  throw new Error(`required hosts mismatch: ${JSON.stringify(required)}`);
}
if (resolver.resolveInstallTargets({}).some((target) => target.includes('.opencode/'))) {
  throw new Error('OpenCode must not be a default target');
}
if (!resolver.resolveInstallTargets({ opencode: true }).some((target) => target.includes('.opencode/'))) {
  throw new Error('explicit OpenCode opt-in was ignored');
}
NODE

    [ "$status" -eq 0 ]
}

@test "install gate verifies an isolated Claude Codex and ZCode mirror" {
    SOURCE="$TMP_DIR/candidate-install/skills/novel-assistant"
    HOME_ROOT="$TMP_DIR/isolated-home"
    mkdir -p "$SOURCE/scripts"
    cat > "$SOURCE/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"candidate","sourceTreeId":"tree","sourceInputDigest":"digest"}
JSON
    printf '# entry\n' > "$SOURCE/SKILL.md"
    cat > "$SOURCE/scripts/workflow-state-machine.js" <<'NODE'
process.stdout.write(JSON.stringify({
  privateRegistryCount: 1,
  templates: [{ workflow_type: 'private_short_startup' }],
}));
NODE
    for host in claude codex zcode; do
        target="$HOME_ROOT/.$host/skills/novel-assistant"
        mkdir -p "$target"
        cp -R "$SOURCE/." "$target/"
    done

    run node - "$GATE" "$TMP_DIR/candidate-install" "$HOME_ROOT" <<'NODE'
const gate = require(process.argv[2]);
const result = gate.gateInstallConsistency(process.argv[3], { installRoot: process.argv[4] });
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
if (result.targets.length !== 3) throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}

@test "install target verifier rejects a manifest-only mirror" {
    SOURCE="$TMP_DIR/source-bundle"
    TARGET="$TMP_DIR/target-bundle"
    mkdir -p "$SOURCE" "$TARGET"
    cat > "$SOURCE/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"candidate","sourceTreeId":"tree","sourceInputDigest":"digest"}
JSON
    cp "$SOURCE/novel-assistant-manifest.json" "$TARGET/novel-assistant-manifest.json"
    printf '# entry\n' > "$SOURCE/SKILL.md"

    run node - "$REPO/scripts/lib/install-target-resolver.js" "$SOURCE" "$TARGET" <<'NODE'
const resolver = require(process.argv[2]);
const result = resolver.verifyBundleTarget(process.argv[3], process.argv[4]);
if (result.ok) throw new Error(JSON.stringify(result));
if (!result.findings.some((finding) => finding.id === 'missing_target_file')) {
  throw new Error(JSON.stringify(result));
}
NODE
    [ "$status" -eq 0 ]
}

@test "install target verifier rejects a mirror without a runnable workflow registry contract" {
    TARGET="$TMP_DIR/no-runtime-target"
    mkdir -p "$TARGET"
    cat > "$TARGET/novel-assistant-manifest.json" <<'JSON'
{"bundleId":"candidate","sourceTreeId":"tree","sourceInputDigest":"digest"}
JSON

    run node - "$REPO/scripts/lib/install-target-resolver.js" "$TARGET" <<'NODE'
const resolver = require(process.argv[2]);
const result = resolver.verifyRuntimeTarget(process.argv[3], 'private');
if (result.ok) throw new Error(JSON.stringify(result));
if (!result.findings.some((finding) => finding.id === 'missing_runtime_workflow_state_machine')) {
  throw new Error(JSON.stringify(result));
}
NODE
    [ "$status" -eq 0 ]
}

@test "public runtime verifier disables ambient private registries before checking an installed bundle" {
    TARGET="$TMP_DIR/public-runtime-target"
    mkdir -p "$TARGET/scripts"
    cat > "$TARGET/scripts/workflow-state-machine.js" <<'NODE'
const isPublicRuntime = process.argv.includes('--no-private-registry');
process.stdout.write(JSON.stringify(isPublicRuntime
  ? { privateRegistryCount: 0, templates: [{ workflow_type: 'short_write' }] }
  : { privateRegistryCount: 1, templates: [{ workflow_type: 'private_short_startup' }] }));
NODE

    run node - "$REPO/scripts/lib/install-target-resolver.js" "$TARGET" <<'NODE'
const resolver = require(process.argv[2]);
const result = resolver.verifyRuntimeTarget(process.argv[3], 'public');
if (!result.ok) throw new Error(JSON.stringify(result));
if (result.privateRegistryCount !== 0 || result.hasPrivateStartup) throw new Error(JSON.stringify(result));
NODE

    [ "$status" -eq 0 ]
}
