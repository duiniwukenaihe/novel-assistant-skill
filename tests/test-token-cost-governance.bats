#!/usr/bin/env bats
# tests/test-token-cost-governance.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/token-cost-ledger.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    COST_REF="$REPO/src/internal-skills/story-workflow/references/token-cost-governance.md"
    CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    LONG_ANALYZE="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    TOP="$REPO/skills/novel-assistant/SKILL.md"
    README="$REPO/README.md"
    DOCS="$REPO/docs/workflow.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    SCRIPTS_README="$REPO/scripts/README.md"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "token cost ledger initializes project workflow cost files" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-cost-001 --workflow-type long_analyze --json > "$TMP_DIR/out.json"

    test -f "$TMP_DIR/book/追踪/workflow/token-cost-ledger.jsonl"
    test -f "$TMP_DIR/book/追踪/workflow/token-cost-summary.json"
    grep -q '"status": "initialized"' "$TMP_DIR/out.json"
    grep -q '"workflow_id": "wf-cost-001"' "$TMP_DIR/out.json"
}

@test "token cost ledger appends proxy metrics and summarizes waste signals" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-cost-002 --workflow-type review --json >/dev/null

    node "$SCRIPT" append \
        --project-root "$TMP_DIR/book" \
        --workflow-id wf-cost-002 \
        --stage stage-2 \
        --module story-review \
        --event-id proxy-waste-001 \
        --model-class deep_reasoning \
        --task-complexity low \
        --input-files 3 \
        --input-chars 18000 \
        --output-chars 9000 \
        --tool-calls 7 \
        --retry-count 2 \
        --failure-count 1 \
        --cache-hit false \
        --status completed \
        --json > "$TMP_DIR/append.json"

    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-cost-002 --json > "$TMP_DIR/summary.json"

    grep -q '"status": "appended"' "$TMP_DIR/append.json"
    grep -q '"events": 1' "$TMP_DIR/summary.json"
    grep -q '"model_mismatch"' "$TMP_DIR/summary.json"
    grep -q '"failure_retry_waste"' "$TMP_DIR/summary.json"
    grep -q '"tool_noise_waste"' "$TMP_DIR/summary.json"
    grep -q '"proactive_alerts"' "$TMP_DIR/summary.json"
    grep -q '"severity": "warning"' "$TMP_DIR/summary.json"
    grep -q '"message": "检测到异常 token 浪费信号"' "$TMP_DIR/summary.json"
    grep -q '"token_saving_plan"' "$TMP_DIR/summary.json"
    grep -q '"active_and_passive"' "$TMP_DIR/summary.json"
    grep -q '"downgrade_model_class"' "$TMP_DIR/summary.json"
    grep -q '"filter_tool_output"' "$TMP_DIR/summary.json"
    grep -q '"stop_retry_and_triage"' "$TMP_DIR/summary.json"
}

@test "token cost ledger keeps actual, estimated, and unavailable usage in separate provenance buckets" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-provenance --workflow-type review --json >/dev/null

    node "$SCRIPT" append \
        --project-root "$TMP_DIR/book" \
        --workflow-id wf-provenance \
        --stage stage-actual \
        --module story-review \
        --token-source host \
        --event-id host-run-001 \
        --input-chars 90000 \
        --output-chars 9000 \
        --input-tokens 120 \
        --output-tokens 30 \
        --cache-read-tokens 8 \
        --cache-write-tokens 4 \
        --duration-ms 200 \
        --json >/dev/null
    node "$SCRIPT" append \
        --project-root "$TMP_DIR/book" \
        --workflow-id wf-provenance \
        --stage stage-estimated \
        --module story-review \
        --token-source estimated \
        --event-id estimate-run-001 \
        --input-chars 200 \
        --output-chars 100 \
        --duration-ms 40 \
        --json >/dev/null
    node "$SCRIPT" append \
        --project-root "$TMP_DIR/book" \
        --workflow-id wf-provenance \
        --stage stage-unavailable \
        --module story-review \
        --token-source unavailable \
        --event-id unavailable-run-001 \
        --duration-ms 20 \
        --json >/dev/null
    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-provenance --json > "$TMP_DIR/summary.json"

    node - "$TMP_DIR/book/追踪/workflow/token-cost-ledger.jsonl" "$TMP_DIR/summary.json" <<'NODE'
const fs = require('fs');
const [ledgerFile, summaryFile] = process.argv.slice(2);
const events = fs.readFileSync(ledgerFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
const actual = events.find((event) => event.event_id === 'host-run-001');
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'));
if (actual.token_source !== 'host') throw new Error(JSON.stringify(actual));
if (actual.estimated_tokens !== 0) throw new Error(`actual event was estimated: ${JSON.stringify(actual)}`);
if (actual.input_tokens !== 120 || actual.output_tokens !== 30 || actual.cache_read_tokens !== 8 || actual.cache_write_tokens !== 4) throw new Error(JSON.stringify(actual));
if (summary.actual.events !== 1 || summary.actual.input_tokens !== 120 || summary.actual.output_tokens !== 30) throw new Error(JSON.stringify(summary.actual));
if (summary.estimated.events !== 1 || summary.estimated.estimated_tokens !== 150) throw new Error(JSON.stringify(summary.estimated));
if (summary.unavailable.events !== 1 || summary.unavailable.duration_ms !== 20) throw new Error(JSON.stringify(summary.unavailable));
if (summary.visible_cost_sources.actual !== '宿主实测') throw new Error(JSON.stringify(summary.visible_cost_sources));
if (summary.visible_cost_sources.estimated !== '代理估算') throw new Error(JSON.stringify(summary.visible_cost_sources));
if (summary.visible_cost_sources.unavailable !== '不可用') throw new Error(JSON.stringify(summary.visible_cost_sources));
NODE
}

@test "token cost ledger rejects incomplete actual usage, de-duplicates event ids, and flags invalid historical metrics" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-integrity --json >/dev/null

    status=0
    node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-integrity --stage stage-1 --module story-review --token-source host --event-id incomplete-host --input-tokens 12 --json > "$TMP_DIR/incomplete.json" 2>&1 || status=$?
    [ "$status" -eq 2 ]
    grep -q 'requires input_tokens and output_tokens' "$TMP_DIR/incomplete.json"

    node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-integrity --stage stage-1 --module story-review --token-source provider --event-id provider-run-001 --input-tokens 10 --output-tokens 5 --json >/dev/null
    node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-integrity --stage stage-1 --module story-review --token-source provider --event-id provider-run-001 --input-tokens 10 --output-tokens 5 --json > "$TMP_DIR/duplicate.json"
    printf '%s\n' '{"event":"cost_observed","workflow_id":"wf-integrity","estimated_tokens":"NaN"}' >> "$TMP_DIR/book/追踪/workflow/token-cost-ledger.jsonl"
    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-integrity --json > "$TMP_DIR/summary.json"

    grep -q '"status": "duplicate_ignored"' "$TMP_DIR/duplicate.json"
    node - "$TMP_DIR/book/追踪/workflow/token-cost-ledger.jsonl" "$TMP_DIR/summary.json" <<'NODE'
const fs = require('fs');
const [ledgerFile, summaryFile] = process.argv.slice(2);
const lines = fs.readFileSync(ledgerFile, 'utf8').trim().split('\n');
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'));
if (lines.filter((line) => line.includes('provider-run-001')).length !== 1) throw new Error(lines.join('\n'));
if (summary.actual.events !== 1 || summary.actual.input_tokens !== 10 || summary.actual.output_tokens !== 5) throw new Error(JSON.stringify(summary.actual));
if (!summary.findings.some((finding) => finding.code === 'invalid_numeric_value')) throw new Error(JSON.stringify(summary.findings));
if (JSON.parse(lines[lines.length - 1]).token_source !== undefined) throw new Error('historical provenance was mutated');
NODE
}

@test "token cost ledger rejects malformed new events and preserves explicit zero estimates" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-validation --json >/dev/null

    for args in \
        "--token-source nonsense --event-id bad-source" \
        "--token-source estimated --event-id bad-actual --input-tokens 0" \
        "--token-source unavailable --event-id bad-estimate --estimated-tokens 0" \
        "--token-source host --event-id bad-negative --input-tokens -1 --output-tokens 1" \
        "--token-source host --event-id bad-nan --input-tokens NaN --output-tokens 1" \
        "--token-source host --event-id bad-infinity --input-tokens Infinity --output-tokens 1"; do
        status=0
        node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-validation --stage stage-1 --module story-review $args --json >/dev/null 2>&1 || status=$?
        [ "$status" -eq 2 ]
    done

    status=0
    node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-validation --stage stage-1 --module story-review --token-source estimated --output-chars 99 --json >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ]

    node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-validation --stage stage-1 --module story-review --token-source estimated --event-id explicit-zero --output-chars 99 --estimated-tokens 0 --json >/dev/null
    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-validation --json > "$TMP_DIR/summary.json"
    node - "$TMP_DIR/summary.json" <<'NODE'
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (summary.estimated.events !== 1 || summary.estimated.estimated_tokens !== 0) throw new Error(JSON.stringify(summary));
NODE
}

@test "token cost ledger de-duplicates historical ids and concurrent appends atomically" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    ledger="$TMP_DIR/book/追踪/workflow/token-cost-ledger.jsonl"
    printf '%s\n%s\n' \
      '{"event":"cost_observed","event_id":"historical-duplicate","workflow_id":"wf-dedupe","token_source":"provider","input_tokens":2,"output_tokens":1}' \
      '{"event":"cost_observed","event_id":"historical-duplicate","workflow_id":"wf-dedupe","token_source":"provider","input_tokens":200,"output_tokens":100}' > "$ledger"

    for i in 1 2 3 4; do
      node "$SCRIPT" append --project-root "$TMP_DIR/book" --workflow-id wf-dedupe --stage stage-1 --module story-review --token-source estimated --event-id concurrent-id --estimated-tokens 9 --json >/dev/null &
    done
    wait
    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-dedupe --json > "$TMP_DIR/summary.json"
    node - "$ledger" "$TMP_DIR/summary.json" <<'NODE'
const fs = require('fs');
const [ledger, summaryFile] = process.argv.slice(2);
const events = fs.readFileSync(ledger, 'utf8').trim().split('\n').map(JSON.parse);
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'));
if (events.filter((event) => event.event_id === 'concurrent-id').length !== 1) throw new Error(JSON.stringify(events));
if (summary.actual.input_tokens !== 2 || summary.actual.output_tokens !== 1) throw new Error(JSON.stringify(summary.actual));
if (summary.estimated.estimated_tokens !== 9) throw new Error(JSON.stringify(summary.estimated));
if (!summary.findings.some((item) => item.code === 'duplicate_event_id')) throw new Error(JSON.stringify(summary.findings));
NODE
}

@test "token cost ledger prints readable cost report in text mode" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" init --project-root "$TMP_DIR/book" --workflow-id wf-cost-readable --workflow-type long_analyze --json >/dev/null
    node "$SCRIPT" append \
        --project-root "$TMP_DIR/book" \
        --workflow-id wf-cost-readable \
        --stage stage-2 \
        --module story-long-analyze \
        --event-id readable-waste-001 \
        --model-class deep_reasoning \
        --task-complexity extract \
        --input-files 80 \
        --input-chars 240000 \
        --output-chars 12000 \
        --tool-calls 10 \
        --retry-count 1 \
        --failure-count 1 \
        --status completed \
        --json >/dev/null

    node "$SCRIPT" summary --project-root "$TMP_DIR/book" --workflow-id wf-cost-readable > "$TMP_DIR/report.txt"

    grep -q "Token Cost Summary" "$TMP_DIR/report.txt"
    grep -q "estimated_tokens" "$TMP_DIR/report.txt"
    grep -q "model_mismatch" "$TMP_DIR/report.txt"
    grep -q "context_thickening_waste" "$TMP_DIR/report.txt"
    grep -q "主动提醒" "$TMP_DIR/report.txt"
    grep -q "异常 token 浪费信号" "$TMP_DIR/report.txt"
    grep -q "节省 token 计划" "$TMP_DIR/report.txt"
    grep -q "downgrade_model_class" "$TMP_DIR/report.txt"
    grep -q "reuse_artifacts_before_raw_read" "$TMP_DIR/report.txt"
    grep -q "建议" "$TMP_DIR/report.txt"
}

@test "token cost governance remains linked from the workflow contract" {
    grep -q "token_cost_governance" "$CONTRACT"
    grep -q "token-cost-governance.md" "$WORKFLOW"
    grep -q "token-cost-ledger.js" "$COST_REF"
}

@test "token cost decision map is centralized in workflow reference" {
    test -f "$COST_REF"
    grep -q "L2 story-workflow owns model_routing_policy" "$COST_REF"
    grep -q "L3 modules obey" "$COST_REF"
    grep -q "cheap_extract" "$COST_REF"
    grep -q "standard_reasoning" "$COST_REF"
    grep -q "deep_reasoning" "$COST_REF"
    grep -q "Task Type Defaults" "$COST_REF"
    grep -q "story-long-analyze" "$COST_REF"
    grep -q "story-review" "$COST_REF"
    grep -q "story-long-write" "$COST_REF"
    grep -q "story-deslop" "$COST_REF"
    grep -q "story-import" "$COST_REF"
    grep -q "Tool Output Policy" "$COST_REF"
    grep -q "Retry and Waste Policy" "$COST_REF"
    grep -q "Ledger Fields" "$COST_REF"
    grep -q "Supervisor Visibility" "$COST_REF"
    grep -q "Stage Completion Visibility" "$COST_REF"
    grep -q "proactive_alerts" "$COST_REF"
    grep -q "abnormal_waste" "$COST_REF"
    grep -q "Active And Passive Reminders" "$COST_REF"
    grep -q "Token Saving Execution Plan" "$COST_REF"
    grep -q "token_saving_plan" "$COST_REF"
    grep -q "reuse_artifacts_before_raw_read" "$COST_REF"
    grep -q "token_source" "$COST_REF"
    grep -q "unavailable" "$COST_REF"
    grep -q "历史账本" "$COST_REF"
}

@test "workflow docs point to canonical token cost reference" {
    grep -q "token-cost-governance.md" "$WORKFLOW"
    grep -q "token-cost-governance.md" "$CONTRACT"
    grep -q "token_cost_governance" "$CONTRACT"
}

@test "long analyze and review modules use cost governance before expensive batches" {
    for file in "$LONG_ANALYZE" "$REVIEW"; do
        grep -q "token_cost_governance" "$file"
        grep -q "token-cost-ledger.js" "$file"
        grep -q "cost_ledger_path" "$file"
        grep -q "model_routing_policy" "$file"
        grep -q "filtered_tool_output" "$file"
        grep -q "不得把原始长输出直接塞回主线程" "$file"
    done
}

@test "top level and docs explain token governance as system behavior" {
    for file in "$README" "$DOCS"; do
        grep -q "Token Cost Governance" "$file"
        grep -q "浪费不可见" "$file"
        grep -q "值得花和该治理分开" "$file"
        grep -q "过程可见" "$file"
        grep -q "经验可沉淀" "$file"
        grep -q "工具输出不原样喂给模型" "$file"
        grep -q "主动提醒" "$file"
        grep -q "被动查询" "$file"
        grep -q "节省 token" "$file"
    done
}

@test "token cost ledger is listed for bundle sync and runtime script index" {
    grep -q "token-cost-ledger.js" "$BUILD"
    grep -q "token-cost-ledger.js" "$SCRIPTS_README"
    test -f "$BUNDLE_NOVEL/scripts/token-cost-ledger.js"
    test -f "$BUNDLE_NOVEL/references/internal-skills/story-workflow/references/token-cost-governance.md"
    cmp "$SCRIPT" "$BUNDLE_NOVEL/scripts/token-cost-ledger.js"
    cmp "$REPO/scripts/workflow-runner.js" "$BUNDLE_NOVEL/scripts/workflow-runner.js"
    cmp "$REPO/scripts/lib/workflow-host-adapters.js" "$BUNDLE_NOVEL/scripts/lib/workflow-host-adapters.js"
    cmp "$REPO/scripts/lib/behavior-eval-contract.js" "$BUNDLE_NOVEL/scripts/lib/behavior-eval-contract.js"
    cmp "$REPO/scripts/behavior-eval.js" "$BUNDLE_NOVEL/scripts/behavior-eval.js"
    cmp "$COST_REF" "$BUNDLE_NOVEL/references/internal-skills/story-workflow/references/token-cost-governance.md"
}

@test "story setup deployment includes token cost ledger runtime script" {
    grep -q "token-cost-ledger.js" "$REPO/src/internal-skills/story-setup/SKILL.md"
    grep -q "token-cost-ledger.js" "$REPO/scripts/check-story-setup-deployment.sh"
    grep -q "token-cost-ledger.js" "$BUNDLE_NOVEL/references/internal-skills/story-setup/SKILL.md"
}
