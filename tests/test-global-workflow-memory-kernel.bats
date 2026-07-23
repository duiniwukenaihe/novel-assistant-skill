#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    POLICY="$REPO/scripts/lib/workflow-memory-policy.js"
    RUNNER="$REPO/scripts/workflow-runner.js"
    STATE="$REPO/scripts/workflow-state-machine.js"
    FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

start_current_stage() {
    node - "$STATE" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const state = process.argv[2];
const root = process.argv[3];
for (let attempt = 0; attempt < 4; attempt += 1) {
  const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
  const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks', pointer.workflow_id, 'task.json'), 'utf8'));
  if (task.stage_execution && task.stage_execution.status === 'running') process.exit(0);
  const pending = task.pending_action || {};
  const option = (pending.options || []).find((item) => Number(item.number) === 1);
  if (!option) throw new Error(`missing option 1: ${JSON.stringify(pending)}`);
  const run = spawnSync(process.execPath, [state, 'resolve-action', '--project-root', root, '--input', '1',
    '--pending-action-id', String(pending.pending_action_id || pending.id || ''),
    '--visible-choice-hash', String(pending.visible_choice_hash || ''),
    '--state-version', String(pending.state_version || task.state_version || ''),
    '--book-root', String(pending.book_root || '.'), '--json'], { encoding: 'utf8' });
  if (run.status !== 0) throw new Error(run.stdout || run.stderr);
}
throw new Error('stage did not start after bounded selections');
NODE
}

@test "every workflow template passes through one explicit memory policy" {
    node - "$STATE" "$POLICY" <<'NODE'
const { spawnSync } = require('child_process');
const state = process.argv[2];
const policyFile = process.argv[3];
const out = spawnSync(process.execPath, [state, 'templates', '--json'], { encoding: 'utf8' });
if (out.status !== 0) throw new Error(out.stderr);
const templates = JSON.parse(out.stdout).templates;
const { resolveWorkflowMemoryPolicy } = require(policyFile);
for (const template of templates) {
  const policy = resolveWorkflowMemoryPolicy(template.workflow_type);
  if (!['required', 'optional', 'none'].includes(policy.mode)) {
    throw new Error(`missing memory policy: ${template.workflow_type}`);
  }
  if (policy.mode !== 'none' && !(policy.token_budget > 0)) {
    throw new Error(`missing memory budget: ${template.workflow_type}`);
  }
}

NODE
}

@test "short prose lifecycle uses one stage context packet instead of a second memory packet" {
    node - "$POLICY" <<'NODE'
const {resolveWorkflowMemoryPolicy}=require(process.argv[2]);
for(const stage of ['draft_first_section','draft_section','draft_next_section','section_repair_loop','section_machine_gate','quality_gate','story_value_gate','section_accept_anchor','full_story_assembly','short_deslop','final_check']) {
  const policy=resolveWorkflowMemoryPolicy('short_write',stage);
  if(policy.mode!=='none' || policy.reason!=='current_story_snapshot_in_stage_context_packet') throw new Error(JSON.stringify({stage,policy}));
}
for(const stage of ['material_card','short_setting','section_outline','first_section_brief','next_section_brief']) {
  const policy=resolveWorkflowMemoryPolicy('short_write',stage);
  if(policy.mode!=='required') throw new Error(JSON.stringify({stage,policy}));
}
NODE
}

@test "every professional module declares the shared workflow and memory boundary" {
    for name in story-long-write story-short-write story-long-analyze story-short-analyze story-long-scan story-short-scan story-review story-deslop story-import story-cover story-setup; do
        file="$REPO/src/internal-skills/$name/SKILL.md"
        grep -q '## L3 Workflow Contract' "$file"
        grep -q 'Inputs From story-workflow' "$file"
        grep -q 'Outputs To story-workflow' "$file"
        grep -q 'Memory Policy' "$file"
    done
}

@test "runner assembles workflow-scoped memory before a creative stage" {
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "继续写第一章" --scope "第1章" --json >/dev/null
    start_current_stage
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/out.json"

    packet="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -name '*.run.json' | head -1)"
    node - "$packet" "$PROJECT" <<'NODE'
const fs = require('fs'); const path = require('path');
const packet = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const root = process.argv[3];
if (packet.memory_context.mode !== 'required') throw new Error(JSON.stringify(packet.memory_context));
if (!packet.memory_context.packet_json || !packet.memory_context.packet_md) throw new Error('missing context packet');
if (!packet.memory_context.packet_json.includes(packet.workflow_id)) throw new Error('context is not workflow scoped');
if (!fs.existsSync(path.join(root, packet.memory_context.packet_json))) throw new Error('context packet not written');
if (!packet.stage_contract || packet.stage_contract.lifecycle_node !== packet.stage_id) throw new Error('missing stage contract');
if (!packet.stage_contract.asset_target || !packet.stage_contract.review_requirement) throw new Error('incomplete stage contract');
if (!packet.result_packet_template || !packet.result_packet_template.asset_revision) throw new Error('missing result packet template');
if (packet.result_packet_template.workflow_id !== packet.workflow_id || packet.result_packet_template.result_packet_path !== packet.expected_result_packet) throw new Error('incomplete result packet identity');
if (!packet.memory_context.memory_contract || !packet.memory_context.memory_read_receipt) throw new Error('missing managed memory contract');
if (packet.result_packet_template.memory_read_receipt.contract_digest !== packet.memory_context.memory_read_receipt.contract_digest) throw new Error('result template did not bind the managed memory receipt');
if (!packet.stage_instruction || !packet.stage_instruction.user_goal || !packet.stage_instruction.owner_module) throw new Error('missing noninteractive stage instruction');
NODE
}

@test "managed runner rejects a result that did not use its memory contract" {
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "继续写第一章" --scope "第1章" --json >/dev/null
    start_current_stage
    cat > "$TMP_DIR/stale-memory-host.js" <<'NODE'
#!/usr/bin/env node
const fs=require('fs'), path=require('path');
const root=process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet=JSON.parse(fs.readFileSync(path.join(root,process.env.NOVEL_ASSISTANT_RUNNER_PACKET),'utf8'));
const result={...(packet.result_packet_template||{}),memory_read_receipt:{...(packet.result_packet_template.memory_read_receipt||{}),memory_revision:'sha256:stale'}};
const target=path.join(root,process.env.NOVEL_ASSISTANT_RESULT_PACKET);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(result));
NODE
    chmod +x "$TMP_DIR/stale-memory-host.js"

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/stale-memory-host.js" --json > "$TMP_DIR/stale-memory-out.json"

    grep -q 'blocked_managed_memory_receipt_invalid' "$TMP_DIR/stale-memory-out.json"
}

@test "setup workflow records an explicit no-fiction-memory decision" {
    node "$STATE" create --workflow-type setup_update --project-root "$PROJECT" --user-goal "刷新协作环境" --json >/dev/null
    start_current_stage
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json >/dev/null

    packet="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -name '*.run.json' | head -1)"
    node - "$packet" <<'NODE'
const fs = require('fs'); const packet = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (packet.memory_context.mode !== 'none') throw new Error(JSON.stringify(packet.memory_context));
if (packet.memory_context.packet_json) throw new Error('setup must not inject fiction memory');
NODE
}

@test "runner records accepted memory updates and auto-applies only safe additions" {
    mkdir -p "$PROJECT/正文/第1卷"
    printf '可信正文证据。\n' > "$PROJECT/正文/第1卷/第001章.md"
    hash="$(shasum -a 256 "$PROJECT/正文/第1卷/第001章.md" | awk '{print $1}')"
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "继续写第一章" --scope "第1章" --json >/dev/null
    start_current_stage
    cat > "$TMP_DIR/memory-host.js" <<NODE
#!/usr/bin/env node
const fs=require('fs'), path=require('path');
const root=process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet=JSON.parse(fs.readFileSync(path.join(root,process.env.NOVEL_ASSISTANT_RUNNER_PACKET),'utf8'));
const result={workflow_id:packet.workflow_id,workflow_type:packet.workflow_type,stage_id:packet.stage_id,step_id:packet.stage_id,owner_module:packet.owner_module,step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',blocking_reason:'',next_recommendation:'继续',handoff_summary:'完成',checkpoint_state:{},output_health_result:'pass',...(packet.result_packet_template||packet.stage_contract||{}),memory_updates:[{action:'create',entryId:'fact.chapter-001',type:'fact',risk:'low',reason:'user accepted fact',evidencePath:'正文/第1卷/第001章.md',proposedContent:'第一章已经建立可信事实。',sourceKind:'user_confirmed',accepted_artifact_id:'manual:chapter-001',sourceRefs:[],affects:['write_chapter','review']}]};
const target=path.join(root,process.env.NOVEL_ASSISTANT_RESULT_PACKET);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(result));
NODE
    chmod +x "$TMP_DIR/memory-host.js"

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/memory-host.js" --json > "$TMP_DIR/out.json"

    grep -q '"memory_projection"' "$TMP_DIR/out.json"
    grep -q 'fact.chapter-001' "$PROJECT/追踪/memory/lorebook.jsonl"
    grep -q '"workflow_id"' "$PROJECT/追踪/memory/lorebook.jsonl"
    grep -q '"workflow_profile":"public"' "$PROJECT/追踪/memory/lorebook.jsonl"
    grep -q 'accepted_memory_updates' "$PROJECT/追踪/workflow/tasks"/*/runner-events/memory-projection.jsonl
}

@test "private short routing metadata is quarantined instead of becoming story canon" {
    node "$STATE" create --workflow-type short_write --project-root "$PROJECT" --user-goal "开始私有短篇写作" --json >/dev/null
    start_current_stage
    cat > "$TMP_DIR/private-short-memory-host.js" <<'NODE'
#!/usr/bin/env node
const fs=require('fs'), path=require('path');
const root=process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet=JSON.parse(fs.readFileSync(path.join(root,process.env.NOVEL_ASSISTANT_RUNNER_PACKET),'utf8'));
const result={workflow_id:packet.workflow_id,workflow_type:packet.workflow_type,stage_id:packet.stage_id,step_id:packet.stage_id,owner_module:packet.owner_module,step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',blocking_reason:'',next_recommendation:'继续',handoff_summary:'完成',checkpoint_state:{},output_health_result:'pass',...(packet.result_packet_template||packet.stage_contract||{}),memory_updates:[{action:'create',entryId:'fact.private-short-route',type:'fact',risk:'low',reason:'user confirmed private short route',proposedContent:'当前本地短篇任务由私有增强流程接管。',sourceKind:'user_confirmed',accepted_artifact_id:'user-confirmed:private-short',sourceRefs:[],affects:['short_write']}]};
const target=path.join(root,process.env.NOVEL_ASSISTANT_RESULT_PACKET);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(result));
NODE
    chmod +x "$TMP_DIR/private-short-memory-host.js"

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/private-short-memory-host.js" --json > "$TMP_DIR/private-short-out.json"

    grep -q '"status": "quarantined_memory_domain_violation"' "$TMP_DIR/private-short-out.json"
    test ! -s "$PROJECT/追踪/memory/lorebook.jsonl"
    grep -q 'fact.private-short-route' "$PROJECT/追踪/workflow/tasks"/*/memory-quarantine/*-domain.json
}

@test "polluted memory updates are quarantined without poisoning lorebook" {
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "继续写第一章" --scope "第1章" --json >/dev/null
    start_current_stage
    cat > "$TMP_DIR/polluted-host.js" <<'NODE'
#!/usr/bin/env node
const fs=require('fs'), path=require('path'); const root=process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet=JSON.parse(fs.readFileSync(path.join(root,process.env.NOVEL_ASSISTANT_RUNNER_PACKET),'utf8'));
const result={workflow_id:packet.workflow_id,workflow_type:packet.workflow_type,stage_id:packet.stage_id,step_id:packet.stage_id,owner_module:packet.owner_module,step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',blocking_reason:'',next_recommendation:'继续',handoff_summary:'完成',checkpoint_state:{},output_health_result:'pass',...(packet.result_packet_template||packet.stage_contract||{}),memory_updates:[{action:'create',entryId:'bad.loop',type:'rule',risk:'low',proposedContent:'剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍剧情节拍。',sourceRefs:[]}]};
const target=path.join(root,process.env.NOVEL_ASSISTANT_RESULT_PACKET);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(result));
NODE
    chmod +x "$TMP_DIR/polluted-host.js"

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/polluted-host.js" --json > "$TMP_DIR/out.json"

    grep -q '"status": "quarantined_output_pollution"' "$TMP_DIR/out.json"
    test ! -s "$PROJECT/追踪/memory/lorebook.jsonl"
    grep -q 'bad.loop' "$PROJECT/追踪/workflow/tasks"/*/memory-quarantine/*.json
}

@test "switching intent preserves the previous task and activate restores its exact checkpoint" {
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "写第一章" --scope "第1章" --json > "$TMP_DIR/first.json"
    first_id="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$TMP_DIR/first.json")"

    node "$STATE" switch-intent --workflow-type review_repair --project-root "$PROJECT" --user-goal "审阅 1-20 章" --scope "1-20" --json > "$TMP_DIR/second.json"
    second_id="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$TMP_DIR/second.json")"

    grep -q '"status": "paused"' "$PROJECT/追踪/workflow/tasks/$first_id/task.json"
    ! grep -q '"status": "superseded"' "$PROJECT/追踪/workflow/tasks/$first_id/task.json"
    node "$STATE" activate --project-root "$PROJECT" --workflow-id "$first_id" --json > "$TMP_DIR/activate.json"
    node - "$TMP_DIR/activate.json" <<'NODE'
const out=require(process.argv[2]);
if(!['activated','stage_started'].includes(out.status)) throw new Error(JSON.stringify(out));
if(out.status==='stage_started' && ((out.stage_execution||{}).status!=='running')) throw new Error(JSON.stringify(out.stage_execution));
NODE
    grep -q "$first_id" "$PROJECT/追踪/workflow/current-task.json"
    grep -q '"status": "paused"' "$PROJECT/追踪/workflow/tasks/$second_id/task.json"
}
