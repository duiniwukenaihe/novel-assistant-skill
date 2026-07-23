#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/behavior-eval.js"
    CONTRACT="$REPO/scripts/lib/behavior-eval-contract.js"
    FACADE="$REPO/scripts/na-dev.js"
    FAKE_HOST="$REPO/tests/fixtures/fake-behavior-eval-host.js"
    NODE_BIN="$(command -v node)"
}

make_fake_hosts() {
    local directory="$1"
    local mode="$2"
    shift 2
    mkdir -p "$directory"
    for host in "$@"; do
        printf '#!/bin/sh\nexec "%s" "%s" "%s"\n' "$NODE_BIN" "$FAKE_HOST" "$mode" > "$directory/$host"
        chmod +x "$directory/$host"
    done
}

@test "direct runEvaluation rejects missing paid authorization before any host resolution" {
    tmp="$(mktemp -d)"
    run_id="direct-gate-${BASHPID}"
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "TEST_TMP=$tmp" node - "$SCRIPT" "$CONTRACT" "$run_id" <<'NODE'
const assert = require('assert/strict');
const runner = require(process.argv[2]);
const contract = require(process.argv[3]);
const runId = process.argv[4];
process.env.PATH = process.env.TEST_TMP;
(async () => {
  const plan = contract.createPlan({ scenario: 'route-single-entry', hosts: 'claude', runId });
  await assert.rejects(() => runner.runEvaluation(plan, { maxBudgetUsd: 10 }), /blocked_paid_confirmation_required/);
  const forged = { ...plan, budget: { ...plan.budget, estimatedUsd: 0.01 } };
  await assert.rejects(() => runner.runEvaluation(forged, { executePaid: true, paidConfirmation: runId, maxBudgetUsd: 10 }), /blocked_budget_estimate_unavailable/);
  assert.equal(require('fs').existsSync(plan.output.absoluteDirectory), false);
})().catch((error) => { console.error(error); process.exit(1); });
NODE

    [ "$status" -eq 0 ]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "paid execution requires a positive aggregate budget before artifacts or hosts" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="missing-budget-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_budget_required'* ]]
    [ ! -e "$REPO/reports/behavior-eval/$run_id" ]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "paid execution reuses the confirmed plan id when run id is omitted" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="confirmed-plan-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
if (result.output.runId !== process.argv[2] || result.status !== "pass") throw new Error(JSON.stringify(result));
' "$output" "$run_id"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "preflight resolves every host before the first paid spawn" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="all-host-preflight-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude,codex --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_host_unavailable'* ]]
    [ ! -e "$REPO/reports/behavior-eval/$run_id/project/fake-host-invocations.log" ]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "fake paid host must materialize fixture and prove every assertion with hashed assets" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="evidence-packet-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude codex zcode
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude,codex,zcode --run-id "$run_id" --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
if (result.status !== "pass" || result.tokenUsage.inputTokens !== 600 || result.tokenUsage.outputTokens !== 60) throw new Error(JSON.stringify(result));
for (const host of result.results) {
  if (host.status !== "pass" || host.assertions.some((item) => item.status !== "pass")) throw new Error(JSON.stringify(host));
  if (!host.usage.complete || host.usage.source !== "host") throw new Error(JSON.stringify(host.usage));
}
' "$output"
    [ -f "$REPO/reports/behavior-eval/$run_id/project/fixture/fixture.json" ]
    [ -f "$REPO/reports/behavior-eval/$run_id/project/artifacts/route.txt" ]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "missing usage or result evidence blocks a completed fake host" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="missing-usage-${BASHPID}"
    make_fake_hosts "$fake_bin" no-usage claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_usage_unavailable'* ]]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "completed host without a verified result packet cannot pass" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="missing-result-${BASHPID}"
    make_fake_hosts "$fake_bin" no-result claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'"status":"fail"'* ]]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "completed host without cost telemetry passes with a token-only receipt" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="missing-cost-${BASHPID}"
    make_fake_hosts "$fake_bin" no-cost claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
if (result.status !== "pass" || result.tokenUsage.inputTokens !== 200 || result.tokenUsage.outputTokens !== 20) throw new Error(JSON.stringify(result));
if (result.results[0].status !== "pass") throw new Error(JSON.stringify(result.results[0]));
if (Object.hasOwn(result.tokenUsage, "actualUsd") || Object.hasOwn(result.tokenUsage, "costSource")) throw new Error(JSON.stringify(result.tokenUsage));
if (Object.hasOwn(result.results[0].usage, "actualUsd") || Object.hasOwn(result.results[0].usage, "costSource")) throw new Error(JSON.stringify(result.results[0].usage));
' "$output"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "ZCode response-only completion preserves behavior evidence while blocking unreported usage" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="zcode-response-${BASHPID}"
    make_fake_hosts "$fake_bin" zcode-response zcode
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts zcode --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    node -e '
const result = JSON.parse(process.argv[1]);
const host = result.results[0];
if (host.status !== "blocked_usage_unavailable" || host.assertions.some((item) => item.status !== "pass")) throw new Error(JSON.stringify(result));
' "$output"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "ZCode local session ledger restores host token receipt without inventing cost" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    home="$tmp/home"
    run_id="zcode-local-usage-${BASHPID}"
    make_fake_hosts "$fake_bin" zcode-local-usage zcode
    mkdir -p "$home/.zcode/cli/db"
    sqlite3 "$home/.zcode/cli/db/db.sqlite" <<'SQL'
create table turn_usage (
  session_id text, trace_id text, status text, provider_id text, model_id text,
  input_tokens integer, output_tokens integer, reasoning_tokens integer,
  cache_creation_input_tokens integer, cache_read_input_tokens integer,
  computed_total_tokens integer, duration_ms integer, completed_at integer
);
insert into turn_usage values (
  'sess_fixture-zcode-usage', 'trace-fixture-zcode-usage', 'completed', 'builtin:test', 'test-model',
  1200, 300, 0, 40, 500, 1540, 9000, 100
);
SQL
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "HOME=$home" "PATH=$fake_bin:$PATH" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts zcode --run-id "$run_id" --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
const host = result.results[0];
if (host.status !== "pass") throw new Error(JSON.stringify(host));
if (!host.usage.complete || host.usage.source !== "host") throw new Error(JSON.stringify(host.usage));
if (host.usage.inputTokens !== 1200 || host.usage.outputTokens !== 300 || host.usage.cacheReadTokens !== 500 || host.usage.cacheWriteTokens !== 40) throw new Error(JSON.stringify(host.usage));
if (host.assertions.some((item) => item.status !== "pass")) throw new Error(JSON.stringify(host.assertions));
' "$output"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "ZCode pretty JSON completion preserves behavior evidence while blocking unreported usage" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="zcode-pretty-${BASHPID}"
    make_fake_hosts "$fake_bin" zcode-pretty-response zcode
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts zcode --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    node -e '
const result = JSON.parse(process.argv[1]);
const host = result.results[0];
if (host.status !== "blocked_usage_unavailable" || host.assertions.some((item) => item.status !== "pass")) throw new Error(JSON.stringify(result));
' "$output"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "Claude terminal total_cost_usd is accepted as authoritative host cost" {
    run node - "$CONTRACT" <<'NODE'
const contract = require(process.argv[2]);
const usage = contract.normalizeUsage('claude', [{
  type: 'result', total_cost_usd: 0.270494,
  usage: { input_tokens: 12, output_tokens: 3, cache_read_input_tokens: 4 },
}]);
if (!usage.complete || usage.actualUsd !== 0.270494 || usage.costSource !== 'host') throw new Error(JSON.stringify(usage));
NODE

    [ "$status" -eq 0 ]
}

@test "provider failures are unavailable while preflight configuration stays distinct" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="provider-unavailable-${BASHPID}"
    make_fake_hosts "$fake_bin" provider-unavailable claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_host_unavailable'* ]]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "budget exhaustion is reported as a budget block instead of host unavailability" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="budget-stop-${BASHPID}"
    make_fake_hosts "$fake_bin" budget-exhausted claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_budget_exhausted'* ]]
    [[ "$output" != *'blocked_host_unavailable'* ]]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "retry aggregates every attempt usage and health event" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="retry-aggregate-${BASHPID}"
    make_fake_hosts "$fake_bin" retry claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
const host = result.results[0];
if (host.retries !== 1 || host.usage.inputTokens !== 300 || host.usage.outputTokens !== 30) throw new Error(JSON.stringify(host));
if (host.healthEvents.length !== 1 || host.healthEvents[0].reason !== "tool_failure_loop") throw new Error(JSON.stringify(host.healthEvents));
if (result.tokenUsage.inputTokens !== 300 || result.tokenUsage.outputTokens !== 30) throw new Error(JSON.stringify(result.tokenUsage));
' "$output"
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "execution helper escalates cleanup for a silent process group" {
    run node - "$SCRIPT" "$NODE_BIN" "$FAKE_HOST" <<'NODE'
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const runner = require(process.argv[2]);
const node = process.argv[3];
const fake = process.argv[4];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'behavior-eval-cleanup-'));
fs.mkdirSync(path.join(root, '.behavior-eval'), { recursive: true });
fs.mkdirSync(path.join(root, 'fixture'));
fs.writeFileSync(path.join(root, 'fixture', 'fixture.json'), '{}');
fs.writeFileSync(path.join(root, '.behavior-eval', 'scenario.json'), JSON.stringify({ scenario: { id: 'route-single-entry', assertions: ['route'] } }));
(async () => {
  const result = await runner.executeInvocation({
    command: node,
    args: [fake, 'silent'],
    cwd: root,
    env: { PATH: process.env.PATH, NOVEL_ASSISTANT_PROJECT_ROOT: root, NOVEL_ASSISTANT_RUNNER_PACKET: '.behavior-eval/scenario.json', NOVEL_ASSISTANT_RESULT_PACKET: '.behavior-eval/result.json' },
    shell: false,
    stdio: ['ignore', 'pipe', 'pipe'],
  }, { timeoutMs: 6000, terminationGraceMs: 40, healthPolicy: { idleTimeoutMs: 3000 }, authorization: { executePaid: true, confirmation: 'fake-cleanup', maxBudgetUsd: 1, estimatedUsd: 0.5 } }, () => {});
  assert.equal(result.health.status, 'blocked');
  assert.ok(result.events.some((event) => event.type === 'ready_for_idle_cleanup'));
  const pids = JSON.parse(fs.readFileSync(path.join(root, 'fake-host-pids.json'), 'utf8'));
  const originalProcessIsAlive = (pid) => {
    try {
      const command = execFileSync('ps', ['-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).trim();
      return command.includes(path.basename(fake)) || command.includes('process.on("SIGTERM"');
    } catch {
      return false;
    }
  };
  const deadline = Date.now() + 5000;
  for (const pid of pids) {
    while (Date.now() < deadline && originalProcessIsAlive(pid)) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(originalProcessIsAlive(pid), false);
  }
  fs.rmSync(root, { recursive: true, force: true });
})().catch((error) => { console.error(error); process.exit(1); });
NODE

    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&3
    fi
    [ "$status" -eq 0 ]
}

@test "artifact sanitization redacts secrets before durable output" {
    run node - "$SCRIPT" <<'NODE'
const runner = require(process.argv[2]);
const value = runner.sanitizeForArtifact({ text: 'Bearer top-secret-token sk-test-abcdefghijklmnopqrstuv api_key=leak-me' });
const serialized = JSON.stringify(value);
if (/top-secret-token|sk-test-|leak-me/.test(serialized)) throw new Error(serialized);
if (!serialized.includes('[REDACTED]')) throw new Error(serialized);
NODE

    [ "$status" -eq 0 ]
}

@test "run root rejects a symlinked reports parent" {
    run node - "$CONTRACT" <<'NODE'
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const contract = require(process.argv[2]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'behavior-eval-root-'));
const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'behavior-eval-outside-'));
const previous = process.cwd();
try {
  fs.symlinkSync(outside, path.join(root, 'reports'));
  process.chdir(root);
  assert.throws(() => contract.createRunDirectory(path.join(root, 'reports', 'behavior-eval', 'paid-test')), /symlink/);
  assert.equal(fs.existsSync(path.join(outside, 'behavior-eval', 'paid-test')), false);
} finally {
  process.chdir(previous);
  fs.rmSync(root, { recursive: true, force: true });
  fs.rmSync(outside, { recursive: true, force: true });
}
NODE

    [ "$status" -eq 0 ]
}

@test "behavior eval defaults to dry run" {
    run node "$SCRIPT" plan --scenario route-single-entry --hosts claude,codex,zcode --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"paidExecution":false'* ]]
}

@test "run rejects missing execute-paid" {
    run node "$SCRIPT" run --scenario route-single-entry --hosts claude --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_paid_confirmation_required'* ]]
}

@test "fixture streams normalize actual usage for every paid host" {
    run node - "$CONTRACT" "$REPO/tests/fixtures/fake-host-events" <<'NODE'
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const contract = require(process.argv[2]);
const fixtureDir = process.argv[3];
const expected = {
  claude: [1200, 340, 180, 60, 1450],
  codex: [980, 275, 220, 0, 1210],
  zcode: [860, 240, 110, 40, 990],
};
for (const [host, values] of Object.entries(expected)) {
  const events = fs.readFileSync(path.join(fixtureDir, `${host}-stream.jsonl`), 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line));
  const usage = contract.normalizeUsage(host, events);
  assert.equal(usage.source, 'host');
  assert.equal(usage.estimated, false);
  assert.deepEqual(
    [usage.inputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens, usage.durationMs],
    values,
  );
}
NODE

    [ "$status" -eq 0 ]
}

@test "paid fixture run creates collision-proof normalized host results" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="fixture-eval-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude codex zcode
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude,codex,zcode --run-id "$run_id" --json

    [ "$status" -eq 0 ]
    node -e '
const result = JSON.parse(process.argv[1]);
if (result.status !== "pass") throw new Error(result.status);
if (result.results.length !== 3) throw new Error("missing hosts");
for (const host of result.results) {
  if (host.status !== "pass" || host.usage.source !== "host" || host.usage.estimated) throw new Error(JSON.stringify(host));
  for (const field of ["assertions", "retries", "healthEvents", "artifacts"]) {
    if (!(field in host)) throw new Error(`missing ${field}`);
  }
}

' "$output"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'run directory already exists'* ]]
    rm -rf "$REPO/reports/behavior-eval/$run_id" "$tmp"
}

@test "paid fixture run formats a non-JSON result without assuming plan commands" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    run_id="fixture-text-${BASHPID}"
    make_fake_hosts "$fake_bin" success claude
    rm -rf "$REPO/reports/behavior-eval/$run_id"

    run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Behavior evaluation: pass'* ]]
    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "plan records scenario hosts execution policy and output without a paid execution" {
    run node "$SCRIPT" plan --scenario write-only-section-6 --hosts claude,codex --json

    [ "$status" -eq 0 ]
    node -e '
const plan = JSON.parse(process.argv[1]);
if (plan.scenario.id !== "write-only-section-6") throw new Error("scenario missing");
if (plan.hosts.join(",") !== "claude,codex") throw new Error("hosts missing");
if (!plan.execution || plan.execution.confirmationRequired !== true) throw new Error("execution policy missing");
if (!/^reports\/behavior-eval\/.+\/$/.test(plan.output.directory)) throw new Error("output missing");
if (!Array.isArray(plan.commands) || plan.commands.length !== 2) throw new Error("commands missing");
' "$output"
}

@test "run-id accepts safe values and rejects traversal outside the report root" {
    run node "$SCRIPT" plan --scenario route-single-entry --hosts claude --run-id "release_2026.07-10" --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"directory":"reports/behavior-eval/release_2026.07-10/"'* ]]

    run node "$SCRIPT" plan --scenario route-single-entry --hosts claude --run-id "../../../outside" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'run-id'* ]]

    run node "$SCRIPT" plan --scenario route-single-entry --hosts claude --run-id "unsafe/id" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'run-id'* ]]

    long_run_id="$(printf '%65s' '' | tr ' ' a)"
    run node "$SCRIPT" plan --scenario route-single-entry --hosts claude --run-id "$long_run_id" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'run-id'* ]]
}

@test "unavailable paid host is blocked without being reported as pass" {
    tmp="$(mktemp -d)"
    sentinel="$tmp/host-called"
    empty_path="$tmp/empty-path"
    run_id="host-unavailable-${BASHPID}"
    mkdir -p "$empty_path"

    run env "PATH=$empty_path" "SENTINEL=$sentinel" "$(command -v node)" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario route-single-entry --hosts claude --run-id "$run_id" --json

    [ "$status" -eq 1 ]
    [[ "$output" == *'blocked_host_unavailable'* ]]
    [ ! -e "$sentinel" ]
    [ -e "$REPO/reports/behavior-eval/$run_id/summary.json" ]

    rm -rf "$tmp" "$REPO/reports/behavior-eval/$run_id"
}

@test "scenario contracts cover each required behavior evaluation fixture" {
    run node - "$CONTRACT" <<'NODE'
const contract = require(process.argv[2]);
const expected = {
  'route-single-entry': ['empty-project', ['route', 'visible_response']],
  'write-only-section-6': ['short-eight-sections', ['target_scope', 'asset_diff']],
  'review-1-200': ['review-range', ['batch_coverage', 'resume']],
  'deconstruction-health-stop': ['fake-degeneration', ['early_stop', 'checkpoint']],
  'review-repair-staged-gate': ['review-repair-gate', ['staged_candidate', 'canonical_unchanged', 'transaction_required']],
  'chapter-commit-conflict': ['chapter-commit-conflict', ['concurrent_change', 'accept_blocked', 'canonical_unchanged']],
  'detail-outline-quality-gate': ['detail-outline-quality-gate', ['routes_to_long_write', 'runs_detail_outline_quality_check', 'underfilled_outline_produces_no_prose', 'accepted_outline_advances_to_chapter_brief', 'result_packet_contains_workflow_and_hash']],
};
for (const [id, [fixture, assertions]] of Object.entries(expected)) {
  const scenario = contract.scenarios[id];
  if (!scenario || scenario.fixture !== fixture) throw new Error(`missing fixture: ${id}`);
  if (JSON.stringify(scenario.assertions) !== JSON.stringify(assertions)) {
    throw new Error(`missing assertions: ${id}`);
  }
}
NODE

    [ "$status" -eq 0 ]
}

@test "detail outline quality behavior fixture is self-contained and dry-run only" {
    run node - "$REPO" "$CONTRACT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const contract = require(process.argv[3]);
const scenario = contract.getScenario('detail-outline-quality-gate');
const fixtureRoot = path.join(root, 'tests/fixtures/behavior-eval/detail-outline-quality-gate');
for (const name of ['fixture.json', 'prompt.md', 'assertions.json']) {
  if (!fs.existsSync(path.join(fixtureRoot, name))) throw new Error(`missing ${name}`);
}
const fixture = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'fixture.json'), 'utf8'));
if (!fixture.validOutline || !fixture.underfilledOutline) throw new Error('two outline cases required');
const assertions = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'assertions.json'), 'utf8'));
if (JSON.stringify(assertions.assertions) !== JSON.stringify(scenario.assertions)) throw new Error('assertion contract mismatch');
const plan = contract.createPlan({ scenario: scenario.id, hosts: 'claude,codex,zcode', runId: 'detail-outline-quality-dry' });
if (plan.paidExecution !== false || plan.commands.some((item) => item.mode !== 'planned_only')) throw new Error(JSON.stringify(plan));
NODE

    [ "$status" -eq 0 ]
}

@test "new transactional scenarios produce dry plans without materializing fixtures or launching hosts" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    make_fake_hosts "$fake_bin" success claude codex zcode

    for scenario in review-repair-staged-gate chapter-commit-conflict; do
        run_id="dry-${scenario}-${BASHPID}"
        rm -rf "$REPO/reports/behavior-eval/$run_id"

        run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" plan --scenario "$scenario" --hosts claude,codex,zcode --run-id "$run_id" --json

        [ "$status" -eq 0 ]
        node -e '
const plan = JSON.parse(process.argv[1]);
const expected = process.argv[2];
if (plan.status !== "dry_run" || plan.paidExecution !== false) throw new Error(JSON.stringify(plan));
if (plan.scenario.id !== expected || plan.commands.some((item) => item.mode !== "planned_only")) throw new Error(JSON.stringify(plan));
' "$output" "$scenario"
        [ ! -e "$REPO/reports/behavior-eval/$run_id" ]
        [ ! -e "$tmp/bin/fake-host-invocations.log" ]
    done

    rm -rf "$tmp"
}

@test "new transactional scenarios materialize isolated fixtures and require all declared evidence" {
    tmp="$(mktemp -d)"
    fake_bin="$tmp/bin"
    make_fake_hosts "$fake_bin" success claude

    for scenario in review-repair-staged-gate chapter-commit-conflict; do
        run_id="fixture-${scenario}-${BASHPID}"
        rm -rf "$REPO/reports/behavior-eval/$run_id"

        run env "PATH=$fake_bin" "$NODE_BIN" "$SCRIPT" run --execute-paid --paid-confirmation "$run_id" --max-budget-usd 10 --scenario "$scenario" --hosts claude --run-id "$run_id" --json

        [ "$status" -eq 0 ]
        node -e '
const result = JSON.parse(process.argv[1]);
if (result.status !== "pass") throw new Error(JSON.stringify(result));
if (result.results[0].assertions.some((item) => item.status !== "pass")) throw new Error(JSON.stringify(result.results[0]));
' "$output"
        [ -f "$REPO/reports/behavior-eval/$run_id/project/fixture/fixture.json" ]
        rm -rf "$REPO/reports/behavior-eval/$run_id"
    done

    rm -rf "$tmp"
}

@test "na-dev behavior-eval prints a dry-run plan without launching a host" {
    run node "$FACADE" behavior-eval --scenario route-single-entry --hosts claude,codex,zcode --json

    [ "$status" -eq 0 ]
    node -e '
const plan = JSON.parse(process.argv[1]);
if (plan.paidExecution !== false) throw new Error("paid execution enabled");
if (!Array.isArray(plan.commands) || plan.commands.length !== 3) throw new Error("planned commands missing");
if (!plan.execution || !plan.output || !plan.output.directory) throw new Error("plan details missing");
' "$output"
}
