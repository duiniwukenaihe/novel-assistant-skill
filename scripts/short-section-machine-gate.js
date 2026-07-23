#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex } = require('./lib/short-workflow-state');
const { deriveSectionLengthPolicy } = require('./lib/short-section-length-policy');
const { atomicWriteJson, mutateTask } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  let task = authority.task;
  if (!['short_write', 'private_short_startup', 'short_startup'].includes(String(task.workflow_type || ''))) {
    return finish({ status: 'blocked_not_short_write', workflow_id: workflowId }, 2, args.json);
  }
  if (String(task.current_stage || '') !== 'section_machine_gate' && (args.recheckPolicy || ['quality_gate', 'story_value_gate', 'section_accept_anchor'].includes(String(task.current_stage || '')))) {
    const recovered = reopenMachineGateForPolicyRecheck(root, task, args.draft);
    if (recovered.status !== 'reopened') return finish(recovered, 0, args.json);
    task = recovered.task;
  }
  if (String(task.current_stage || '') !== 'section_machine_gate') {
    return finish({ status: 'stage_action_not_applicable', expected: 'section_machine_gate', actual: task.current_stage || '', instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  }
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'section_machine_gate') {
    return finish({ status: 'stage_execution_not_ready', workflow_id: workflowId, instruction: '先由工作流启动机器门，再运行本命令。' }, 0, args.json);
  }

  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const sectionIndex = inferShortSectionIndex({
    projectState,
    stageId: 'section_machine_gate',
    scope: String(task.scope || ''),
  });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复小节范围，不得默认检查第1节。' }, 0, args.json);
  const preparedDraft = prepareExistingRevisionDraft(root, task, execution, sectionIndex, args.draft);
  const draft = resolveDraft(root, task, sectionIndex, args.draft);
  if (!draft) return finish({ status: 'short_draft_missing', section_index: sectionIndex, instruction: '返回当前节草稿阶段恢复候选稿。' }, 0, args.json);

  const draftText = fs.readFileSync(draft, 'utf8');
  const actualChars = (draftText.match(/[\u3400-\u9fff]/g) || []).length;
  const lengthPolicy = deriveSectionLengthPolicy({ projectState, sectionIndex, actual: actualChars });
  const checks = [
    ...runChecks(root, draft),
    {
      id: 'short-section-length-policy',
      status: lengthPolicy.blocking ? 'blocking' : lengthPolicy.status,
      blocking: lengthPolicy.blocking === true,
      exit_code: 0,
      finding_count: lengthPolicy.blocking ? 1 : 0,
      message: lengthPolicy.blocking ? lengthPolicy.note : '',
      details: lengthPolicy,
    },
  ];
  const blocking = checks.filter((item) => item.blocking);
  const packetRel = String(execution.expected_result_packet || `追踪/workflow/tasks/${workflowId}/result-packets/section_machine_gate.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_result_packet_path_unsafe', path: packetRel }, 2, args.json);
  const evidenceRel = `追踪/workflow/tasks/${workflowId}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-machine-gate.json`;
  const evidenceFile = safeProjectFile(root, evidenceRel);
  const draftRel = relative(root, draft);
  const draftDigest = digestFile(draft);
  atomicWriteJson(evidenceFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    section_index: sectionIndex,
    draft: draftRel,
    draft_digest: draftDigest,
    checks,
    length_policy: lengthPolicy,
    blocking_count: blocking.length,
    created_at: new Date().toISOString(),
  });

  const passed = blocking.length === 0;
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'section_machine_gate',
    step_id: 'section_machine_gate',
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: passed ? 'completed' : 'blocked',
    outputs: [draftRel, evidenceRel],
    changed_files: preparedDraft ? [preparedDraft] : [],
    created_files: [evidenceRel, ...(preparedDraft ? [preparedDraft] : [])],
    evidence: checks.map((item) => ({ check: item.id, status: item.status, blocking: item.blocking, finding_count: item.finding_count })),
    verification_result: passed ? 'pass' : 'blocking',
    machine_gate_result: passed ? 'pass' : 'blocking',
    draft_digest: draftDigest,
    length_policy: lengthPolicy,
    blocking_findings: blocking.map((item) => ({ code: item.id, message: item.message || `${item.id} 未通过` })),
    checkpoint_state: {
      current_stage: 'section_machine_gate',
      completed_range: passed ? `第${sectionIndex}节机器门完成` : '',
      remaining_range: passed ? '短篇质量门与采用锚点' : `第${sectionIndex}节修订循环`,
      resume_from: passed ? 'quality_gate' : 'section_repair_loop',
      prose_write_allowed: !passed,
    },
    output_health_result: passed ? 'pass' : 'blocking',
    current_section_index: sectionIndex,
    next_recommendation: passed ? '进入当前节故事质量门' : '只修复当前节 blocking 后重新运行机器门',
    handoff_summary: passed ? `第${sectionIndex}节机器门通过。` : `第${sectionIndex}节机器门发现 ${blocking.length} 项 blocking。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });

  if (!args.apply) {
    return finish({ status: passed ? 'packet_ready' : 'revision_required', workflow_id: workflowId, section_index: sectionIndex, result_packet: packetRel, evidence: evidenceRel, length_policy: lengthPolicy }, 0, args.json);
  }
  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'),
    'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  const applyResult = outcome.result;
  const nextStage = String(applyResult.current_stage || ((applyResult.task || {}).current_stage) || (passed ? 'quality_gate' : 'section_repair_loop'));
  const nextExecution = applyResult.stage_execution || ((applyResult.task || {}).stage_execution) || {};
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    section_index: sectionIndex,
    gate_status: passed ? 'pass' : 'blocking',
    result_packet: packetRel,
    evidence: evidenceRel,
    next_stage: nextStage,
    stage_execution: nextExecution,
    context_packet: String((((nextExecution.stage_context_packet || {}).packet_md) || '')),
    next_command: String(nextExecution.execution_command || ''),
    resume_hint: String(nextExecution.resume_hint || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { apply_result: applyResult }),
  }, outcome.exitCode, args.json);
}

function reopenMachineGateForPolicyRecheck(root, task, explicitDraft) {
  const stage = String(task.current_stage || '');
  const execution = task.stage_execution || {};
  if (!['quality_gate', 'story_value_gate', 'section_accept_anchor'].includes(stage)
    || String(execution.status || '') !== 'running'
    || String(execution.stage_id || '') !== stage) {
    return {
      status: 'policy_recheck_not_applicable',
      workflow_id: String(task.workflow_id || ''),
      actual_stage: stage,
      instruction: '规则重验只用于机器门已通过、当前正等待故事质量判断的同一份候选稿。',
    };
  }

  const sectionIndex = inferShortSectionIndex({
    projectState: readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {},
    stageId: 'section_machine_gate',
    scope: String(task.scope || ''),
  });
  if (!sectionIndex) return { status: 'blocked_short_section_identity_missing' };
  const packetDir = `${String(task.task_dir || '')}/result-packets`;
  const unitPacketRel = `${packetDir}/section_machine_gate.section-${String(sectionIndex).padStart(3, '0')}.result.json`;
  const legacyPacketRel = `${packetDir}/section_machine_gate.result.json`;
  const packetRel = fs.existsSync(safeProjectFile(root, unitPacketRel)) ? unitPacketRel : legacyPacketRel;
  const packet = readJson(safeProjectFile(root, packetRel));
  if (!packet || String(packet.machine_gate_result || packet.verification_result || '') !== 'pass') {
    return { status: 'policy_recheck_proof_missing', workflow_id: String(task.workflow_id || ''), reason: 'previous_machine_gate_not_passed' };
  }
  const outputs = Array.isArray(packet.outputs) ? packet.outputs.map(String) : [];
  const artifactRel = outputs.find((item) => /machine-gate\.json$/.test(item)) || '';
  const artifact = readJson(safeProjectFile(root, artifactRel));
  const draft = resolveDraft(root, task, sectionIndex, explicitDraft);
  const expectedDigest = String((artifact || {}).draft_digest || '');
  if (!draft || !/^sha256:[a-f0-9]{64}$/.test(expectedDigest)) {
    return { status: 'policy_recheck_proof_missing', workflow_id: String(task.workflow_id || ''), reason: 'previous_machine_gate_digest_missing' };
  }

  const now = new Date().toISOString();
  const workflowId = String(task.workflow_id || '');
  const resultPacket = `${String(task.task_dir || '')}/result-packets/section_machine_gate.result.json`;
  const next = mutateTask({
    projectRoot: root,
    workflowId,
    expectedStateVersion: Number(task.state_version || 0),
    owner: 'short-section-machine-gate-policy-recheck',
    mutation: (current) => {
      const machine = current.machine || (current.machine = {});
      const resetStages = new Set(['section_machine_gate', 'section_repair_loop', 'quality_gate', 'story_value_gate', 'section_accept_anchor']);
      machine.completed_stages = (Array.isArray(machine.completed_stages) ? machine.completed_stages : [])
        .filter((item) => !resetStages.has(String(item)));
      const downstream = (Array.isArray(machine.remaining_stages) ? machine.remaining_stages : [])
        .filter((item) => !resetStages.has(String(item)));
      machine.remaining_stages = ['section_machine_gate', 'section_repair_loop', 'quality_gate', ...downstream];
      machine.last_transition = 'machine_gate_policy_recheck_started';
      machine.next_stop_reason = 'stage_running_waiting_result_packet';
      machine.allowed_actions = ['await_result_packet', 'pause'];
      current.current_stage = 'section_machine_gate';
      current.current_step = 'section_machine_gate';
      current.status = 'running';
      current.pending_action = null;
      current.stage_execution = {
        status: 'running',
        stage_attempt_id: `sa-${workflowId}-section_machine_gate-policy-recheck`,
        stage_id: 'section_machine_gate',
        step_id: 'section_machine_gate',
        action_id: 'recheck_gate_policy',
        selected_number: 0,
        started_at: now,
        expected_result_packet: resultPacket,
        owner_module: String(current.workflow_owner || ''),
        write_set: [],
        completion_boundary: 'stage_completed',
        execution_command: `node scripts/short-section-machine-gate.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --apply --json`,
        resume_hint: '检测规则已更新；直接重跑同一候选稿的机器门，不读取正文之外的文件，不重写正文。',
      };
      current.runtime_guard = current.runtime_guard || {};
      current.runtime_guard.heartbeat = {
        ...(current.runtime_guard.heartbeat || {}),
        updated_at: now,
        current_batch: 'section_machine_gate',
        workflow_id: workflowId,
      };
      current.runtime_guard.checkpoint_policy = {
        ...(current.runtime_guard.checkpoint_policy || {}),
        resume_from: 'section_machine_gate',
        expected_result_packet: resultPacket,
        project_root: '.',
      };
      return current;
    },
  });
  return { status: 'reopened', task: next };
}

function runChecks(root, draft) {
  const commands = [
    ['check-ai-patterns', 'check-ai-patterns.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['anti-ai-diagnose', 'anti-ai-diagnose.js', ['--json', '--work-type=shortform', '--prose-profile=fiction', draft]],
    ['output-pollution-check', 'output-pollution-check.js', ['--check', '--json', draft]],
    ['check-degeneration', 'check-degeneration.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['story-prose-gate', 'story-prose-gate.js', [draft, '--json']],
  ];
  return commands.map(([id, script, cliArgs]) => {
    const run = spawnSync(process.execPath, [path.join(__dirname, script), ...cliArgs], {
      cwd: root,
      encoding: 'utf8',
      maxBuffer: 4 * 1024 * 1024,
    });
    const parsed = parseJson(run.stdout);
    const findingCount = countFindings(parsed);
    const blocking = run.status !== 0 || hasBlocking(parsed);
    return {
      id,
      status: blocking ? 'blocking' : 'pass',
      blocking,
      exit_code: Number.isInteger(run.status) ? run.status : 1,
      finding_count: findingCount,
      message: blocking ? firstMessage(parsed, run.stderr) : '',
    };
  });
}

function resolveDraft(root, task, sectionIndex, explicit) {
  const candidates = [];
  if (explicit) candidates.push(explicit);
  const padded = String(sectionIndex).padStart(3, '0');
  candidates.push(`草稿_第${padded}节_候选.md`, `正文_第${padded}节.md`);
  const previousPacket = readJson(safeProjectFile(root, String(((task.machine || {}).last_result_packet) || '')) || '');
  const packetDrafts = ((previousPacket || {}).outputs || [])
    .map(String)
    .filter((output) => /(?:草稿_第\d+节_候选|正文_第\d+节)\.md$/u.test(output));
  candidates.unshift(...packetDrafts);
  for (const candidate of candidates) {
    const file = safeProjectFile(root, candidate);
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) return file;
  }
  return '';
}

function prepareExistingRevisionDraft(root, task, execution, sectionIndex, explicit) {
  if (explicit || resolveDraft(root, task, sectionIndex, '')) return '';
  const queueItem = (Array.isArray(((task || {}).feedback_revision_queue || {}).items)
    ? task.feedback_revision_queue.items
    : []).find((item) => Number((item || {}).section_index || 0) === Number(sectionIndex));
  if (String((queueItem || {}).prose_status || '') !== 'pending_recheck') return '';
  const padded = String(sectionIndex).padStart(3, '0');
  const sourceRel = `正文/第${padded}节.md`;
  const targetRel = `草稿_第${padded}节_候选.md`;
  const source = safeProjectFile(root, sourceRel);
  const target = safeProjectFile(root, targetRel);
  if (!source || !target || !fs.existsSync(source) || !fs.statSync(source).isFile()) return '';
  fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
  execution.recheck_source = sourceRel;
  execution.draft_target = targetRel;
  execution.write_set = [targetRel];
  return targetRel;
}

function hasBlocking(value) {
  if (!value || typeof value !== 'object') return false;
  if (Array.isArray(value)) return value.some(hasBlocking);
  for (const [key, child] of Object.entries(value)) {
    if (/blocking_count|blockingCount|blocking/i.test(key) && typeof child === 'number' && child > 0) return true;
    if (/blocking|blocked/i.test(key) && child === true) return true;
    if (/status|result|verdict/i.test(key) && typeof child === 'string' && /(block|fail|reject|error)/i.test(child)) return true;
    if (/severity/i.test(key) && String(child).toLowerCase() === 'blocking') return true;
    if (hasBlocking(child)) return true;
  }
  return false;
}

function countFindings(value) {
  if (!value || typeof value !== 'object') return 0;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + countFindings(item), 0);
  let count = 0;
  for (const [key, child] of Object.entries(value)) {
    if (/findings/i.test(key) && Array.isArray(child)) count += child.length;
    else count += countFindings(child);
  }
  return count;
}

function firstMessage(parsed, stderr) {
  const stack = [parsed];
  while (stack.length) {
    const item = stack.shift();
    if (!item || typeof item !== 'object') continue;
    if (typeof item.message === 'string' && item.message.trim()) return item.message.trim().slice(0, 300);
    stack.push(...(Array.isArray(item) ? item : Object.values(item)));
  }
  return String(stderr || '').trim().slice(0, 300);
}

function focusedWorkflowId(root) {
  return singleUnfinishedWorkflowId(root);
}

function safeProjectFile(root, input) {
  const value = String(input || '').trim();
  if (!value) return '';
  const file = path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
  return file === root || !file.startsWith(`${root}${path.sep}`) ? '' : file;
}

function relative(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function digestFile(file) {
  return `sha256:${require('crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function readJson(file) {
  try { return file && fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null; } catch (_) { return null; }
}

function parseJson(text) {
  const value = String(text || '').trim();
  if (!value) return null;
  try { return JSON.parse(value); } catch (_) {
    const lines = value.split(/\r?\n/).filter(Boolean);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      try { return JSON.parse(lines[index]); } catch (_) { /* continue */ }
    }
    return null;
  }
}

function parseArgs(argv) {
  const out = { projectRoot: '', workflowId: '', draft: '', apply: false, recheckPolicy: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--draft') out.draft = argv[++index] || '';
    else if (arg === '--apply' || arg === '--write') out.apply = true;
    else if (arg === '--recheck-policy' || arg === '--recheck') out.recheckPolicy = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
  }
  return out;
}

function printHelp() {
  process.stdout.write('Usage: node short-section-machine-gate.js --project-root <book> --workflow-id <id> [--draft file] [--recheck-policy] [--apply] [--json]\n');
  return 0;
}

function finish(payload, code, json) {
  process.stdout.write(`${json ? JSON.stringify(payload) : JSON.stringify(payload, null, 2)}\n`);
  process.exitCode = code;
}

main();
