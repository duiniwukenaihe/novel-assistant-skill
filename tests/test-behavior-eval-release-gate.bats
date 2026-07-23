#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GATE="$REPO/scripts/behavior-eval-release-gate.js"
    STATUS="$REPO/scripts/release-status.js"
    TMP_DIR="$(mktemp -d)"
    FIXTURE="$TMP_DIR/repo"
    cp -R "$REPO" "$FIXTURE"
    rm -rf "$FIXTURE/.git" "$FIXTURE/reports"
    mkdir -p "$FIXTURE/reports/behavior-eval"
    BUNDLE_ID="$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).bundleId)" "$REPO/skills/novel-assistant/novel-assistant-manifest.json")"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_report() {
    local scenario="$1"
    local run_id="$2"
    local status_value="${3:-pass}"
    local bundle_id="${4:-$BUNDLE_ID}"
    local paid="${5:-true}"
    local usage_source="${6:-host}"
    mkdir -p "$FIXTURE/reports/behavior-eval/$run_id"
    node - "$FIXTURE/reports/behavior-eval/$run_id/summary.json" "$scenario" "$status_value" "$bundle_id" "$paid" "$usage_source" <<'NODE'
const fs=require('fs');
const [file,scenario,status,bundleId,paid,usageSource]=process.argv.slice(2);
const hosts=['claude','codex','zcode'];
const assertionsByScenario={
  'route-single-entry':['route','visible_response'],
  'write-only-section-6':['target_scope','asset_diff'],
  'review-1-200':['batch_coverage','resume'],
  'deconstruction-health-stop':['early_stop','checkpoint'],
  'review-repair-staged-gate':['staged_candidate','canonical_unchanged','transaction_required'],
  'chapter-commit-conflict':['concurrent_change','accept_blocked','canonical_unchanged'],
};
const assertions=(assertionsByScenario[scenario]||['unknown']).map(name=>({name,status:'pass',evidence:[{path:'artifacts/evidence.txt',sha256:'0'.repeat(64)}]}));
const complete=usageSource==='host';
const summary={
  status,
  paidExecution: paid==='true',
  scenario:{id:scenario,assertions:assertions.map(a=>a.name)},
  hosts,
  release_evidence:{bundleId,sourceCommit:'test-commit',hostVersions:{claude:'test',codex:'test',zcode:'test'}},
  budget:{actualUsd:complete?0.6:null,actualUsdStatus:complete?'host_reported':'blocked_cost_unavailable',durationMs:1234},
  results:hosts.map(host=>({
    host,
    status,
    assertions,
    usage:{complete,source:usageSource,costSource:complete?'host':'unavailable',actualUsd:complete?0.2:null,inputTokens:100,outputTokens:10,durationMs:100},
  })),
};
fs.writeFileSync(file,JSON.stringify(summary,null,2));
NODE
}

write_all_reports() {
    for scenario in route-single-entry write-only-section-6 review-1-200 deconstruction-health-stop review-repair-staged-gate chapter-commit-conflict; do
        write_report "$scenario" "paid-$scenario"
    done
}

@test "release gate blocks when required behavior reports are missing" {
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'"status":"blocked"'* ]]
    [[ "$output" == *'missing_scenarios'* ]]
}

@test "release gate blocks dry-run or non-paid reports" {
    write_all_reports
    write_report "write-only-section-6" "paid-write-only-section-6" pass "$BUNDLE_ID" false
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'not_paid_execution'* ]]
}

@test "release gate blocks stale bundle evidence" {
    write_all_reports
    write_report "review-1-200" "paid-review-1-200" pass "bundle-stale"
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'bundle_mismatch'* ]]
}

@test "release gate blocks missing host usage provenance" {
    write_all_reports
    write_report "deconstruction-health-stop" "paid-deconstruction-health-stop" pass "$BUNDLE_ID" true estimated
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 1 ]
    [[ "$output" == *'usage_not_host_reported'* ]]
}

@test "release gate accepts complete host usage without cost telemetry" {
    write_all_reports
    for scenario in route-single-entry write-only-section-6 review-1-200 deconstruction-health-stop review-repair-staged-gate chapter-commit-conflict; do
        write_report "$scenario" "paid-$scenario" pass "$BUNDLE_ID" true host
        node - "$FIXTURE/reports/behavior-eval/paid-$scenario/summary.json" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const summary=JSON.parse(fs.readFileSync(file,'utf8'));
summary.budget.actualUsd=null;
summary.budget.actualUsdStatus='unavailable';
for (const result of summary.results) {
  result.usage.actualUsd=null;
  result.usage.costSource='unavailable';
}
fs.writeFileSync(file,JSON.stringify(summary,null,2));
NODE
    done
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"pass"'* ]]
}

@test "release gate passes complete paid reports and release-status exposes result" {
    write_all_reports
    run node "$GATE" --repo-root "$FIXTURE" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"pass"'* ]]
    run node "$STATUS" --repo-root "$FIXTURE" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"behaviorGate"'* ]]
    [[ "$output" == *'"status":"pass"'* ]]
}
