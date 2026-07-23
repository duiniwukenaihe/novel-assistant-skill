#!/usr/bin/env bats
# tests/test-workflow-stage-controller.bats
#
# 固化短篇逐节写正文时第六节 draft_next_section 完成后必须直接进入
# section_machine_gate 的回归测试。对应"短篇第六节失控排障"事故。
#
# Task 3 在此扩充以下覆盖：
#   1. 正常推进（Task 1 RED，实现后变 GREEN）：draft_next_section → section_machine_gate，recovery_count=0。
#   2. 陈旧 state version 一次恢复：result 携带旧 state_version，控制器从权威任务重读后再试一次，recovered_once。
#   3. 私有 registry 临时缺失：不得降级，直接 blocked（复用 Task 2 身份校验），status 不是 recovered_once。
#   4. 相同转换连续失败：第二次必须 paused + retry_budget_result=exhausted，last_trusted_artifact 不变。
#   5. transition service 回环路由单元测试：draft_next_section allowed_next fallback 到 section_machine_gate。
#
# 永久 invariant：仓库内不得出现 debug-*/scan-*/find-*/inspect-* 脚本。

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/workflow-state-machine.js"
    CONTROLLER="$REPO/scripts/workflow-stage-controller.js"
    FIXTURE="$REPO/tests/fixtures/behavior-eval/short-sixth-section/fixture.json"
    export WORKFLOW_TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
}

teardown() {
    rm -rf "$TMP_DIR"
}

focused_task_file() {
    node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(process.argv[1]))" "$1"
}

migrate_legacy_fixture() {
    printf '%s\n' 'source=worldwonderer/oh-story-claudecode' > "$1/.story-deployed"
    node "$REPO/scripts/task-family-migrate.js" --project-root "$1" --source oh-story --write --confirm --json >/dev/null
}

# 把 fixture.json 落成一本可被控制器操作的真实私有短篇书目。
# 参照 test-workflow-state-machine.bats:3364 的 resume 测试构造方式：
#   - mkdir + cat heredoc + migrate_legacy_fixture
#   - 任务目录: 追踪/workflow/tasks/<workflow_id>/task.json + result-packets/
#   - anchor:   追踪/private-short-extension/section-NNN-anchor.json（带真实 sha256）
materialize_fixture() {
    local book="$1"
    node - "$FIXTURE" "$book" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const book = process.argv[3];
const wf = fixture.workflow;
const taskId = wf.workflow_id;

fs.mkdirSync(path.join(book, '追踪/workflow/tasks', taskId, 'result-packets'), {recursive: true});
fs.mkdirSync(path.join(book, '追踪/private-short-extension'), {recursive: true});

// 正文.md：拼接已采用的第 1-5 节作为 canonical 资产。
const canon = fixture.canonical_asset;
const proseBody = canon.sections.map((s) => s.body).join('\n');
fs.writeFileSync(path.join(book, canon.path), proseBody);
const canonicalSha = crypto.createHash('sha256').update(proseBody).digest('hex');

// anchor 文件：每节 accepted，sha256 用真实 canonical 正文哈希。
for (const section of fixture.accepted_sections) {
    const anchor = {
        workflow_id: taskId,
        section_index: section.section_index,
        status: 'accepted',
        canonical_path: canon.path,
        canonical_sha256: canonicalSha,
        quality_result: fixture.anchor_quality_result
    };
    fs.writeFileSync(path.join(book, section.anchor_path), JSON.stringify(anchor) + '\n');
}

// 第六节 Brief。
const brief = fixture.sixth_section_brief;
fs.writeFileSync(path.join(book, brief.path), brief.body + '\n');

// 结果包：draft_next_section 已完成。
const packet = fixture.result_packet;
packet.payload.owner_module = packet.payload.owner_module || wf.workflow_owner;
fs.writeFileSync(path.join(book, packet.path), JSON.stringify(packet.payload, null, 2) + '\n');

// task.json：停在 draft_next_section，scope=第6节，私有短篇身份。
const task = {
    schemaVersion: '1.0.0',
    state_version: 1,
    workflow_id: taskId,
    workflow_type: wf.workflow_type,
    workflow_profile: wf.workflow_profile,
    workflow_owner: wf.workflow_owner,
    status: wf.status,
    scope: wf.scope,
    completion_policy: wf.completion_policy,
    task_dir: `追踪/workflow/tasks/${taskId}`,
    book_root: wf.book_root,
    current_stage: wf.current_stage,
    current_step: wf.current_step,
    machine: {
        completed_stages: fixture.machine.completed_stages,
        remaining_stages: fixture.machine.remaining_stages
    },
    runtime_guard: {
        heartbeat: {latest_trusted_artifact: ''},
        checkpoint_policy: {},
        max_retry_budget: {same_failure: 1, on_exhausted: 'pause_at_checkpoint'}
    },
    pending_action: {id: 'pa-advance', status: 'pending', options: [{number: 1, target_stage: 'section_machine_gate'}]},
    short_project_resume: {
        latest_brief: brief.path,
        accepted_sections: fixture.accepted_sections
    }
};
fs.writeFileSync(path.join(book, `追踪/workflow/tasks/${taskId}/task.json`), JSON.stringify(task, null, 2) + '\n');

// current-task.json 指针：task_dir + state_version + workflow_id（migrate 后会被聚焦工具读取）。
const pointer = {
    schemaVersion: '1.0.0',
    state_version: task.state_version,
    workflow_id: taskId,
    task_dir: task.task_dir,
    focused_at: new Date().toISOString()
};
fs.writeFileSync(path.join(book, '追踪/workflow/current-task.json'), JSON.stringify(pointer, null, 2) + '\n');
NODE
    migrate_legacy_fixture "$book"
}

@test "short sixth section draft_next_section advances directly to section_machine_gate without runaway recovery" {
    [ -f "$FIXTURE" ]
    materialize_fixture "$BOOK"

    # 断言 1：控制器把 draft_next_section 的完成结果推进到 section_machine_gate，
    # 且 recovery_count 为 0。Task 1 阶段 controller 尚不存在，此断言失败（RED）。
    run node "$CONTROLLER" advance \
        --project-root "$BOOK" \
        --workflow-id wf-short-sixth \
        --result "$BOOK/追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json" \
        --json
    [ "$status" -eq 0 ]
    if ! node -e 'const x=JSON.parse(process.argv[1]);if(x.next_stage!=="section_machine_gate"||x.recovery_count!==0)process.exit(1)' "$output"; then printf '%s\n' "$output" >&2; fi
    node -e 'const x=JSON.parse(process.argv[1]);if(x.next_stage!=="section_machine_gate"||x.recovery_count!==0)process.exit(1)' "$output"

    # 断言 2：单次推进只产生一次任务 journal transition（不得重复写）。
    local journal="$BOOK/追踪/workflow/tasks/wf-short-sixth/journal.jsonl"
    [ -f "$journal" ]
    local count
    count=$(grep -c '"event":"advanced"' "$journal" || true)
    [ "$count" -eq 1 ]

    # 断言 3：永久 invariant —— 仓库内不得为排障事故新建 debug/find/inspect
    # 一次性脚本。scan-* 排除已存在的三个生产扫描工具
    # (scan-json-validate / scan-download-hints / scan-artifact-build)，
    # 这些是结构化产物构建工具，不是失控排障脚本。
    run bash -c "find '$REPO/scripts' -maxdepth 1 -type f \( -name 'debug-*' -o -name 'find-*' -o -name 'inspect-*' \) -print"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # scan-* 排除已存在的三个生产扫描工具（必须带 .js 全名，find -name 匹配整个 basename）。
    run bash -c "find '$REPO/scripts' -maxdepth 1 -type f -name 'scan-*' -not -name 'scan-json-validate.js' -not -name 'scan-download-hints.js' -not -name 'scan-artifact-build.js' -print"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "advanceStage recovers once when state version is stale then succeeds" {
    [ -f "$FIXTURE" ]
    materialize_fixture "$BOOK"

    # 人为把 task.json 的 state_version 抬到 7，再用 --expected-state-version 1
    # 模拟宿主在并发修改前读到的旧快照。控制器应：第 1 次 mutateTask 因版本
    # 冲突失败（recoverable_transition_failure），重读权威任务后再试一次 → recovered_once。
    local task_file
    task_file=$(focused_task_file "$BOOK")
    node - "$task_file" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
const t = JSON.parse(fs.readFileSync(p, 'utf8'));
t.state_version = 7;
fs.writeFileSync(p, JSON.stringify(t, null, 2) + '\n');
NODE

    run node "$CONTROLLER" advance \
        --project-root "$BOOK" \
        --workflow-id wf-short-sixth \
        --result "$BOOK/追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json" \
        --expected-state-version 1 \
        --json
    [ "$status" -eq 0 ]
    node -e 'const x=JSON.parse(process.argv[1]); if(x.status!=="recovered_once"||x.next_stage!=="section_machine_gate"||x.recovery_count!==1) process.exit(1)' "$output"
}

@test "advanceStage blocks without downgrade when private registry is unavailable" {
    [ -f "$FIXTURE" ]
    materialize_fixture "$BOOK"

    # 用 --no-private-registry 让 registry 不可用。私有任务身份校验必须直接 blocked，
    # 不得降级到公开模板，也不得进入 recovered_once 路径（registry 真的不可用，重试无意义）。
    run node "$CONTROLLER" advance \
        --project-root "$BOOK" \
        --workflow-id wf-short-sixth \
        --result "$BOOK/追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json" \
        --no-private-registry \
        --json
    # blocked 不一定是进程退出码非 0；以 JSON status 为准。
    node - "$output" <<'NODE'
const x = JSON.parse(process.argv[2]);
if (!/^blocked/.test(String(x.status || ''))) process.exit(1);
if (x.status === 'recovered_once') process.exit(1);
NODE

    # 任务仍是 running，没被改成 paused，也没有任何 retry_budget_result=exhausted。
    local task_file
    task_file=$(focused_task_file "$BOOK")
    node - "$task_file" <<'NODE'
const t = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (t.status !== 'running') process.exit(1);
NODE
}

@test "advanceStage pauses after two consecutive same transition failures with retry_budget_result exhausted and last_trusted_artifact preserved" {
    [ -f "$FIXTURE" ]
    materialize_fixture "$BOOK"

    # 用一个会让 transition service 在“写正文”类阶段之外持续 blocked 的结果包：
    # step_status=blocked 触发 resultHasBlocking，draft_next_section 没有声明 failure_return，
    # 所以 transition 返回 blocked=true、reason=stage_blocked_at_declared_loop 但
    # next_stage_id 可能为空。无论 next 是否为空，blocked 会把控制器推到恢复路径。
    local blocked_packet="$BOOK/追踪/workflow/tasks/wf-short-sixth/result-packets/blocked.result.json"
    cat > "$blocked_packet" <<'JSON'
{
  "workflow_id": "wf-short-sixth",
  "workflow_type": "short_write",
  "owner_module": "private-short-extension",
  "stage_id": "draft_next_section",
  "step_id": "draft_next_section",
  "step_status": "blocked",
  "verification_result": "fail",
  "blocking_reason": "simulated runaway blocker",
  "changed_files": []
}
JSON

    # 先在 task 里写一个非空 last_trusted_artifact，断言它不被改写。
    local task_file
    task_file=$(focused_task_file "$BOOK")
    node - "$task_file" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
const t = JSON.parse(fs.readFileSync(p, 'utf8'));
t.runtime_guard = t.runtime_guard || {};
t.runtime_guard.heartbeat = t.runtime_guard.heartbeat || {};
t.runtime_guard.heartbeat.latest_trusted_artifact = '追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json';
fs.writeFileSync(p, JSON.stringify(t, null, 2) + '\n');
NODE

    # 第一次推进：draft_next_section blocked → recoverable_transition_failure（recover once 用尽）。
    # 控制器内部重试一次仍然 blocked → 第二次失败 → paused_transition_failure。
    run node "$CONTROLLER" advance \
        --project-root "$BOOK" \
        --workflow-id wf-short-sixth \
        --result "$blocked_packet" \
        --json
    node - "$output" <<'NODE'
const x = JSON.parse(process.argv[2]);
if (x.status !== 'paused_transition_failure') process.exit(1);
NODE

    # 任务必须 paused，retry_budget_result=exhausted，last_trusted_artifact 保留原值。
    node - "$task_file" <<'NODE'
const t = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (t.status !== 'paused') process.exit(1);
const budget = ((t.runtime_guard || {}).max_retry_budget || {});
if (budget.retry_budget_result !== 'exhausted') process.exit(2);
const trusted = ((t.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact || '';
if (trusted !== '追踪/workflow/tasks/wf-short-sixth/result-packets/draft_next_section.result.json') process.exit(3);
NODE

    # 暂停路径必须同时写全局 history.jsonl 和任务 journal.jsonl，与成功推进
    # 路径一致（运维按 workflow_id 查 journal.jsonl 必须能看到 pause 事件）。
    local journal="$BOOK/追踪/workflow/tasks/wf-short-sixth/journal.jsonl"
    [ -f "$journal" ]
    local journal_pause_count
    journal_pause_count=$(grep -c '"event":"paused_transition_failure"' "$journal" || true)
    [ "$journal_pause_count" -eq 1 ]

    # 永久 invariant：仓库内不得为排障事故新建 debug/find/inspect 一次性脚本。
    # scan-* 排除已存在的三个生产扫描工具。
    run bash -c "find '$REPO/scripts' -maxdepth 1 -type f \( -name 'debug-*' -o -name 'find-*' -o -name 'inspect-*' \) -print"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # scan-* 排除已存在的三个生产扫描工具（必须带 .js 全名，find -name 匹配整个 basename）。
    run bash -c "find '$REPO/scripts' -maxdepth 1 -type f -name 'scan-*' -not -name 'scan-json-validate.js' -not -name 'scan-download-hints.js' -not -name 'scan-artifact-build.js' -print"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "transition service resolves draft_next_section loop fallback to section_machine_gate via allowed_next" {
    # 纯单元测试：直接 require transition service，验证回环路由修复。
    # draft_next_section 在私有 registry 里排在 section_machine_gate 之前，
    # 线性 nextLinearStage 找不到后必须 fallback 到 allowed_next[0]=section_machine_gate。
    REPO_DIR="$REPO" node - <<'NODE'
const path = require('path');
const repo = process.env.REPO_DIR;
const { buildEffectiveTemplates } = require(path.join(repo, 'scripts/lib/workflow-template-registry.js'));
const { createWorkflowTransitionService } = require(path.join(repo, 'scripts/lib/workflow-transition-service.js'));

const registryRoot = path.join(repo, 'src/private-internal-skills');
const { templates } = buildEffectiveTemplates(registryRoot, false);
const tpl = templates.short_write;

const service = createWorkflowTransitionService({
    findStage: (t, id) => (t.stages || []).find((s) => s.stage_id === id),
    currentUnitRole: () => 'draft_or_execute',
    unitLifecycle: () => ({ stage_roles: {}, required_sequence: [] }),
    validateLifecycleTransition: () => ({ allowed: true }),
});

const machine = { completed_stages: [], remaining_stages: [] };
const result = {
    workflow_id: 'wf-x', workflow_type: 'short_write',
    stage_id: 'draft_next_section', step_id: 'draft_next_section',
    step_status: 'completed', verification_result: 'pass',
};
const transition = service.resolveStageTransition(tpl, machine, 'draft_next_section', result, { workflow_type: 'short_write' }, '');
if (transition.blocked) { process.stderr.write('unexpected blocked: ' + transition.reason + '\n'); process.exit(1); }
if (transition.next_stage_id !== 'section_machine_gate') {
    process.stderr.write('expected section_machine_gate, got: ' + transition.next_stage_id + '\n');
    process.exit(2);
}
NODE
}
