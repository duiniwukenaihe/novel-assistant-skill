#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "task complexity policy keeps current-unit writing single-agent" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { classifyTaskComplexity } = require(path.join(process.argv[2], 'scripts/lib/task-complexity-policy.js'));

const result = classifyTaskComplexity({
  workflowType: 'short_write',
  stageId: 'draft_section',
  inputFiles: 4,
  inputChars: 18000,
  unitCount: 1,
  riskLevel: 'medium',
  independentDomains: ['prose'],
});

assert.equal(result.size_class, 'small');
assert.equal(result.recommended_agent_count, 1);
assert.equal(result.context_strategy, 'current_unit_only');
assert.equal(result.model_class, 'standard_reasoning');
assert(result.reason_codes.includes('canonical_single_writer'));
NODE
}

@test "task complexity policy sends deterministic checks to scripts without agents" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const path = require('path');
const { classifyTaskComplexity } = require(path.join(process.argv[2], 'scripts/lib/task-complexity-policy.js'));

const result = classifyTaskComplexity({
  workflowType: 'short_write',
  stageId: 'section_machine_gate',
  inputFiles: 2,
  inputChars: 12000,
  unitCount: 1,
  riskLevel: 'low',
});

assert.equal(result.size_class, 'small');
assert.equal(result.recommended_agent_count, 0);
assert.equal(result.model_class, 'cheap_extract');
assert.equal(result.execution_topology, 'deterministic_script');
NODE
}

@test "task complexity policy batches large reviews before bounded parallel dispatch" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const path = require('path');
const { classifyTaskComplexity } = require(path.join(process.argv[2], 'scripts/lib/task-complexity-policy.js'));

const result = classifyTaskComplexity({
  workflowType: 'review_repair',
  stageId: 'classify_findings',
  inputFiles: 200,
  inputChars: 700000,
  unitCount: 200,
  riskLevel: 'high',
  independentDomains: ['plot', 'hooks', 'character', 'canon', 'prose'],
  maxParallelAgents: 3,
});

assert.equal(result.size_class, 'large');
assert.equal(result.execution_topology, 'batch_then_parallel_read');
assert.equal(result.recommended_agent_count, 3);
assert.equal(result.model_class, 'deep_reasoning');
assert(result.reason_codes.includes('large_input_scope'));
NODE
}

@test "workflow creation persists an executable complexity decision" {
    mkdir -p "$TMP_DIR/short" "$TMP_DIR/review/正文"
    printf '正文\n' > "$TMP_DIR/review/正文/chapter001.md"
    printf '正文\n' > "$TMP_DIR/review/正文/chapter002.md"

    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$TMP_DIR/short" --user-goal "写一个短篇" --json > "$TMP_DIR/short.json"
    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type review_repair --project-root "$TMP_DIR/review" --scope 1-2 --user-goal "审阅 1-2 章" --json > "$TMP_DIR/review.json"

    node - "$TMP_DIR/short.json" "$TMP_DIR/review.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [short, review] = process.argv.slice(2).map((file) => JSON.parse(fs.readFileSync(file, 'utf8')).task);
assert.equal(short.runtime_guard.complexity_policy.size_class, 'small');
assert.equal(short.runtime_guard.complexity_policy.recommended_agent_count, 1);
assert.equal(short.runtime_guard.token_estimate.agent_count, 1);
assert(review.runtime_guard.complexity_policy);
assert.equal(review.runtime_guard.complexity_policy.execution_topology, 'single_agent');
NODE
}

@test "runner packet exposes the stage-specific execution policy" {
    node - "$REPO" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const path = require('path');
const { buildRunPreview } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const task = {
  workflow_id: 'wf-short', workflow_type: 'short_write', task_dir: '追踪/workflow/tasks/wf-short', scope: '第3节',
  runtime_guard: { token_estimate: { input_files: 4, input_chars_estimate: 18000, risk_level: 'medium' } },
};
const run = buildRunPreview(process.argv[3], task, {
  stage_id: 'draft_section', expected_result_packet: '追踪/workflow/tasks/wf-short/result-packets/draft.result.json',
}, { adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: '/bin/true', fakeMode: 'success' }, 0, {
  mode: 'none', status: 'stage_context_packet_only', packet_md: '', packet_json: '', accepts_memory_updates: false,
});
assert.equal(run.runnerPacket.execution_policy.size_class, 'small');
assert.equal(run.runnerPacket.execution_policy.recommended_agent_count, 1);
assert(run.runnerPacket.requirements.some((line) => line.includes('不得派发额外 Agent')));
NODE
}

@test "runner prompts share a stable protocol prefix before dynamic task context" {
    node - "$REPO" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { buildRunPreview, STABLE_HARNESS_PREFIX } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
function preview(id, stage) {
  return buildRunPreview(process.argv[3], {
    workflow_id: id, workflow_type: 'short_write', task_dir: `追踪/workflow/tasks/${id}`, scope: '当前节', runtime_guard: { token_estimate: {} },
  }, { stage_id: stage, expected_result_packet: `追踪/workflow/tasks/${id}/result.json` }, {
    adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: '/bin/true', fakeMode: 'success',
  }, 0, { mode: 'none', status: 'stage_context_packet_only' });
}
const first = preview('wf-one', 'draft_section');
const second = preview('wf-two', 'repair_section');
const firstPrompt = fs.readFileSync(first.invocation.env.NOVEL_ASSISTANT_PROMPT_FILE, 'utf8');
const secondPrompt = fs.readFileSync(second.invocation.env.NOVEL_ASSISTANT_PROMPT_FILE, 'utf8');
assert(firstPrompt.startsWith(`${STABLE_HARNESS_PREFIX}\n--- 动态任务上下文 ---\n`));
assert(secondPrompt.startsWith(`${STABLE_HARNESS_PREFIX}\n--- 动态任务上下文 ---\n`));
assert.equal(first.runnerPacket.prompt_prefix_digest, second.runnerPacket.prompt_prefix_digest);
NODE
}

@test "runner result template carries trusted artifact identities between stages" {
    node - "$REPO" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const path = require('path');
const { buildRunPreview } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const run = buildRunPreview(process.argv[3], {
  workflow_id: 'wf-artifacts', workflow_type: 'short_write', task_dir: '追踪/workflow/tasks/wf-artifacts', runtime_guard: { token_estimate: {} },
}, { stage_id: 'draft_section', expected_result_packet: '追踪/workflow/tasks/wf-artifacts/result.json' }, {
  adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: '/bin/true', fakeMode: 'success',
}, 0, { mode: 'none', status: 'stage_context_packet_only' }, {
  status: 'assembled', packet_md: 'packet.md', packet_json: 'packet.json',
  source_files: [{ id: 'brief', artifact_id: 'artifact:brief-v1', path: 'brief.md', kind: 'brief' }],
});
assert.deepEqual(run.runnerPacket.consumed_artifact_ids, ['artifact:brief-v1']);
assert.deepEqual(run.runnerPacket.result_packet_template.consumed_artifact_ids, ['artifact:brief-v1']);
assert.deepEqual(run.runnerPacket.result_packet_template.produced_artifact_ids, []);
NODE
}

@test "review batch dispatch is capped by the executable complexity policy" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const path = require('path');
const { planReviewBatches } = require(path.join(process.argv[2], 'scripts/lib/review-batch-planner.js'));
const chapters = Array.from({ length: 60 }, (_, index) => ({
  chapterKey: `c${index + 1}`,
  globalDraftOrder: index + 1,
  volume: '第一卷',
  chars: 5000,
  staticRiskTags: index === 0 ? ['high_conflict'] : [],
  boundaryTags: [],
}));
const plan = planReviewBatches({
  chapters,
  parentScope: '1-60',
  requiredDimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
  budgetPolicy: { host_context_chars: 3000000, max_source_context_ratio: 0.3, max_parallel_agents: 3 },
  availableAgents: ['story-explorer', 'character-designer', 'narrative-writer', 'consistency-checker'],
});
const batch = plan.batches[0];
assert.equal(batch.complexity_policy.size_class, 'large');
assert.equal(batch.complexity_policy.recommended_agent_count, 3);
assert.equal(batch.dispatch_plan.roles.length, 3);
assert(batch.dispatch_plan.deferredDimensions.length > 0);
NODE
}

@test "runner cost ledger records executable complexity instead of risk labels" {
    node - "$REPO" "$TMP_DIR/ledger-project" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { recordCost } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-telemetry.js'));
const root = process.argv[3];
fs.mkdirSync(root, { recursive: true });
const task = {
  workflow_id: 'wf-cost',
  workflow_type: 'short_write',
  runtime_guard: {
    token_estimate: { input_files: 4, input_chars_estimate: 18000, risk_level: 'medium' },
    complexity_policy: { size_class: 'small', model_class: 'standard_reasoning' },
  },
};
const result = recordCost(root, task, { stage_id: 'draft_section' }, {}, {
  run_id: 'run-cost-1', attempt: 0, duration_ms: 20,
  exit: { code: 0 }, health: { status: 'healthy', total_bytes: 1000 },
  usage: { token_source: 'unavailable', duration_ms: 20, findings: [] },
  prompt_envelope: { stable_prefix_digest: 'sha256:stable', dynamic_context_digest: 'sha256:dynamic' },
}, 'story-short-write');
assert.equal(result.ok, true);
const ledger = fs.readFileSync(path.join(root, '追踪/workflow/token-cost-ledger.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
const event = ledger.find((entry) => entry.event_id === 'run-cost-1');
assert.equal(event.task_complexity, 'small');
assert.equal(event.model_class, 'standard_reasoning');
assert.equal(event.input_files, 4);
assert.equal(event.input_chars, 18000);
assert.equal(event.stable_prefix_digest, 'sha256:stable');
assert.equal(event.dynamic_context_digest, 'sha256:dynamic');
NODE
}
