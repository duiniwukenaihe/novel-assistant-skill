#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    SNAPSHOT="$REPO/tests/helpers/workflow-cli-contract-snapshot.js"
    FIXTURE="$REPO/tests/fixtures/workflow-cli-contracts/command-facade.json"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "workflow state machine preserves the public command facade" {
    run node "$SNAPSHOT" "$STATE" "$BOOK"
    [ "$status" -eq 0 ]
    if [ "${UPDATE_WORKFLOW_CLI_CONTRACT_FIXTURE:-0}" = "1" ]; then
        mkdir -p "$(dirname "$FIXTURE")"
        printf '%s\n' "$output" > "$FIXTURE"
    fi
    [ -f "$FIXTURE" ]
    diff -u "$FIXTURE" <(printf '%s\n' "$output")
}

@test "workflow command registry keeps public and mutating command sets explicit" {
    run node - "$REPO/scripts/lib/workflow-command-registry.js" <<'NODE'
const registry = require(process.argv[2]);
const expected = ['templates', 'create', 'inspect', 'resolve-action', 'apply-result', 'next-candidates', 'switch-intent', 'activate', 'migrate-legacy', 'migrate-longform-successor', 'reset-incompatible-review-batches', 'continue-review-with-legacy-evidence', 'restore-incomplete-workflow', 'reset-unmanaged-review-repair', 'reconcile-runtime', 'refresh-short-title-lock', 'resume-pending-short-feedback', 'discard-short-feedback-item', 'reclassify-short-feedback-item', 'migrate-short-lean-workflow'];
if (JSON.stringify(registry.PUBLIC_COMMANDS) !== JSON.stringify(expected)) throw new Error(JSON.stringify(registry.PUBLIC_COMMANDS));
for (const command of ['create', 'resolve-action', 'apply-result', 'switch-intent', 'activate', 'reconcile-runtime']) {
  if (!registry.isMutatingCommand(command)) throw new Error(`missing mutating command: ${command}`);
}
if (registry.isMutatingCommand('templates') || registry.isMutatingCommand('inspect')) throw new Error('read-only command marked mutating');
NODE
    [ "$status" -eq 0 ]
}

@test "workflow lifecycle service preserves stage stop and artifact rules" {
    run node - "$REPO/scripts/lib/workflow-lifecycle-service.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const stage = { stage_id: 'write', requires_user_confirm: false, risk_level: 'high' };
if (lifecycle.findStage({ stages: [stage] }, 'write') !== stage) throw new Error('stage lookup drift');
if (!lifecycle.shouldStopBeforeStage({ completion_policy: 'full_auto' }, stage)) throw new Error('high-risk full-auto stage must stop');
if (lifecycle.nextStopReason({ completion_policy: 'full_auto' }, stage) !== 'requires_user_confirm') throw new Error('stop reason drift');
if (lifecycle.currentUnitRole({ stage_roles: { write: 'draft_or_execute' } }, 'write') !== 'draft_or_execute') throw new Error('unit role drift');
if (lifecycle.trustedArtifactFromResult({ outputs: ['正文.md'] }) !== '正文.md') throw new Error('trusted artifact drift');
NODE
    [ "$status" -eq 0 ]
}

@test "workflow transition service keeps gate repair and longform rollback rules pure" {
    run node - "$REPO/scripts/lib/workflow-transition-service.js" <<'NODE'
const { createWorkflowTransitionService } = require(process.argv[2]);
const findStage = (template, id) => template.stages.find((stage) => stage.stage_id === id) || null;
const service = createWorkflowTransitionService({
  findStage,
  currentUnitRole: (contract, id) => (contract.stage_roles || {})[id] || '',
  unitLifecycle: () => ({ unit_type: 'workflow_batch', stage_roles: {} }),
  validateLifecycleTransition: (from, to) => ({ allowed: from === 'review' && to === 'asset', from, to }),
});
const gateTemplate = {
  workflow_type: 'short_write',
  stages: [
    { stage_id: 'gate', allowed_next: ['repair', 'quality'] },
    { stage_id: 'repair', allowed_next: ['quality'] },
    { stage_id: 'quality', allowed_next: [] },
  ],
  unit_lifecycle_contract: { stage_roles: { gate: 'machine_quality_gate', quality: 'quality_gate' } },
};
const blocked = service.resolveStageTransition(gateTemplate, { completed_stages: [] }, 'gate', { step_status: 'blocked' });
if (blocked.next_stage_id !== 'repair' || blocked.reason !== 'machine_gate_blocked_current_unit') throw new Error(JSON.stringify(blocked));
const passed = service.resolveStageTransition(gateTemplate, { completed_stages: [] }, 'gate', { step_status: 'completed', verification_result: 'pass' });
if (passed.next_stage_id !== 'quality' || passed.reason !== 'machine_gate_passed') throw new Error(JSON.stringify(passed));
const longTemplate = {
  workflow_type: 'long_write',
  stages: [
    { stage_id: 'asset', allowed_next: ['review'] },
    { stage_id: 'review', allowed_next: [], review_requirement: { required: true, failure_return: 'asset' } },
  ],
};
const rollback = service.resolveStageTransition(longTemplate, { completed_stages: ['asset'] }, 'review', { step_status: 'blocked' });
if (rollback.next_stage_id !== 'asset' || rollback.reason !== 'review_failed_return_to_asset') throw new Error(JSON.stringify(rollback));
NODE
    [ "$status" -eq 0 ]
}

@test "workflow recovery service keeps lease and trusted checkpoint decisions explicit" {
    run node - "$REPO/scripts/lib/workflow-recovery-service.js" <<'NODE'
const { createWorkflowRecoveryService } = require(process.argv[2]);
const service = createWorkflowRecoveryService({
  exists: (file) => file === '/book/追踪/workflow/tasks/wf/rpd.md',
  resolveInsideProject: (root, file) => `${root}/${file}`,
  durableTaskSnapshotPath: () => '追踪/workflow/tasks/wf/task.json',
});
if (!service.isLiveWorkflowSessionLease({ holder_id: 'claude:1', expires_at: '2030-01-01T00:00:00.000Z' }, new Date('2029-01-01T00:00:00.000Z'))) throw new Error('live lease drift');
if (service.isLiveWorkflowSessionLease({ holder_id: 'claude:1', expires_at: '2028-01-01T00:00:00.000Z' }, new Date('2029-01-01T00:00:00.000Z'))) throw new Error('expired lease drift');
const checkpoint = service.trustedRuntimeCheckpoint({ repair_integrity_recovery: { requires_current_text_recheck: true }, rpd_path: '追踪/workflow/tasks/wf/rpd.md' }, '/book');
if (checkpoint !== '追踪/workflow/tasks/wf/rpd.md') throw new Error(`checkpoint drift: ${checkpoint}`);
NODE
    [ "$status" -eq 0 ]
}

@test "workflow user menu renders visible review scope instead of internal execution details" {
    run node - "$REPO/scripts/lib/workflow-user-menu.js" <<'NODE'
const { renderTaskMarkdown } = require(process.argv[2]);
const text = renderTaskMarkdown({
  workflow_id: 'wf-test', workflow_type: 'review_repair', user_goal: '内部目标', scope: 'internal', status: 'running', completion_policy: 'stage_then_confirm', current_stage: 'evidence_scan', current_step: 'evidence_scan',
  lifecycle: { status: 'active' }, machine: { remaining_stages: ['classify_findings'] },
  review_target: { visible_label: '审阅第 1 卷', narrative_scope: '第 1 卷' },
  stage_execution: { status: 'running', stage_id: 'evidence_scan', expected_result_packet: 'internal.json', resume_hint: 'internal' },
  pending_action: { options: [{ number: 1, label: '继续审阅' }] },
});
if (!text.includes('用户目标：审阅第 1 卷') || !text.includes('范围：第 1 卷')) throw new Error(text);
if (text.includes('预期回执：internal.json')) throw new Error('internal execution detail leaked');
NODE
    [ "$status" -eq 0 ]
}
