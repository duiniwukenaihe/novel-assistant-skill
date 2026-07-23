'use strict';

// workflow-runner-execution
//
// Responsibility boundary: this module ONLY runs one host invocation for a
// single workflow stage. It produces the host's result packet; it does NOT
// advance the workflow to the next stage.
//
// Stage advancement is a separate concern and must be delegated to the
// single-command atomic stage controller (`scripts/workflow-stage-controller.js`
// → lib/workflow-stage-controller.advanceStage). The host / orchestrator must
// never hand-chain inspect / apply-result / reconcile-runtime to "push" a stage
// forward — that hand-chain is what caused the short-sixth-section runaway-token
// incident (a routing edge case returned the wrong next stage and the host
// entered a hundred-call debugging loop). advanceStage collapses stage advance
// into one transactional call with a once-only recovery + circuit breaker.
//
// If you need to advance after runHost writes a result packet, call:
//   node scripts/workflow-stage-controller.js advance \
//     --project-root <book> --workflow-id <id> --result <result.json> --json

const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { buildAdapterInvocation, composeStageContextGuidance } = require('./workflow-host-adapters');
const { createStreamHealthMonitor } = require('./workflow-stream-health');
const { appendJsonl, atomicWriteJson } = require('./workflow-state-store');
const { normalizeExecutionBoundary } = require('./workflow-execution-boundary');
const { sanitizeForArtifact, terminateProcessGroup } = require('../behavior-eval');
const {
  cancelBudgetReservation,
  collectHostEvent,
  normalizeHostUsage,
  recordCost,
  refreshRunnerLease,
  releaseRunnerLease,
  resolveRunnerTask,
  reserveBudget,
  settleBudget,
} = require('./workflow-runner-telemetry');

const SCRIPT_DIR = path.resolve(__dirname, '..');
const TERMINATION_GRACE_MS = 3000;

let templateOwnerCache = null;
function buildRunPreview(root, task, execution, options, attempt, memoryContext, stageContextPacket = null) {
  const runId = `${task.workflow_id}-${execution.stage_id}-a${attempt + 1}-${Date.now()}`;
  const runnerPacketRel = `${task.task_dir}/runner-packets/${execution.stage_id}.attempt-${attempt + 1}.run.json`;
  const expectedResultPacket = execution.expected_result_packet;
  const stageContract = stageContractFor(task, execution);
  const stageContextOk = stageContextPacket
    && stageContextPacket.status === 'assembled'
    && Boolean(stageContextPacket.packet_md);
  // I1: inject the collaboration advisory so managed_runner hosts surface the
  // managed-mode handoff hint when context bloats. composeStageContextGuidance
  // returns '' when there is no usable packet (fail-open), so it is safe to
  // append unconditionally — empty strings are filtered out below.
  const stageContextGuidance = stageContextOk
    ? composeStageContextGuidance(stageContextPacket)
    : '';
  const runnerPacket = {
    schemaVersion: '1.0.0',
    run_id: runId,
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    owner_module: ownerModuleFor(task, execution.stage_id),
    project_root: root,
    // Focus is a UI concern. The runner must always read the immutable task
    // snapshot that it claimed before the host process was started.
    task_state: `${task.task_dir}/task.json`,
    host_execution_mode: 'managed_runner',
    execution_boundary_capabilities: normalizeExecutionBoundary({ host_execution_mode: 'managed_runner', runnerOwnedChild: true }),
    expected_result_packet: expectedResultPacket,
    stage_instruction: stageInstructionFor(task, execution, stageContract),
    memory_context: memoryContext,
    // stage_context_packet is the minimum allowlist for short-write prose draft
    // stages. When present, the prose Agent must read packet_md and stay inside
    // its asset list instead of free-searching the journal / result-packets /
    // scripts. Absent (null) for non-draft or non-short stages — fail-open.
    stage_context_packet: stageContextOk ? {
      status: 'assembled',
      packet_md: stageContextPacket.packet_md,
      packet_json: stageContextPacket.packet_json || '',
      section_index: stageContextPacket.section_index || null,
      estimated_tokens: stageContextPacket.estimated_tokens || 0,
      token_budget: stageContextPacket.token_budget || 0,
      source_files: Array.isArray(stageContextPacket.source_files) ? stageContextPacket.source_files.slice() : [],
      memory_contract: stageContextPacket.memory_contract || null,
      memory_read_receipt: stageContextPacket.memory_read_receipt || null,
    } : null,
    attempt: attempt + 1,
    max_attempts: options.maxRetries + 1,
    execution_boundary: execution.completion_boundary || 'stop_after_stage',
    // The host must echo this immutable contract in its result packet. Keeping
    // it in the runner packet makes the packet genuinely self-sufficient.
    stage_contract: stageContract,
    result_packet_template: resultPacketTemplateFor(
      task,
      execution,
      stageContract,
      expectedResultPacket,
      runnerPacketRel,
      memoryContext,
    ),
    requirements: [
      '使用 novel-assistant 入口并路由到 owner_module',
      '只执行当前 stage，不提前执行下一阶段',
      '只向 expected_result_packet 写入符合 result contract 的 JSON',
      '不要把完整正文或工具日志复制到最终回复',
      memoryContext.mode === 'none'
        ? '本阶段已明确不注入小说创作记忆'
        : `先读取 memory_context.packet_md，只使用与 workflow_id 和目标范围匹配的记忆`,
      // For short-write draft stages the stage_context_packet is the single
      // allowlist. For other stages stage_context_packet is null and this
      // requirement is a no-op.
      stageContextOk
        ? `先读取 stage_context_packet.packet_md（${stageContextPacket.packet_md}），只使用包内资产写正文，不得自由搜索其他文件或读取全量 journal/result-packets/scripts`
        : '若无 stage_context_packet，按 owner_module 默认资产范围执行',
      // I1: collaboration-mode advisory — surface the managed_runner handoff
      // hint when the packet is valid. Empty when guidance is not applicable.
      ...(stageContextGuidance ? [stageContextGuidance] : []),
      '输出退化或工具连续失败时立即停止，不伪造完成',
    ],
  };
  const prompt = buildPrompt(runnerPacketRel, expectedResultPacket, task, execution, attempt);
  const invocation = buildAdapterInvocation(options.adapter, {
    projectRoot: root,
    prompt,
    runId,
    runnerPacket: runnerPacketRel,
    expectedResultPacket,
    maxBudgetUsd: options.maxBudgetUsd,
    fakeExecutable: options.fakeExecutable,
    fakeArgs: [options.fakeMode],
  });
  return { runId, runnerPacketRel, runnerPacket, invocation, attempt };
}

function stageContractFor(task, execution) {
  const stageId = String(execution.stage_id || task.current_stage || '');
  const graphNode = Array.isArray((task.lifecycle_graph || {}).nodes)
    ? task.lifecycle_graph.nodes.find((node) => node && node.id === stageId)
    : null;
  return {
    owner_module: String((graphNode && graphNode.owner_module) || ownerModuleFor(task, stageId) || ''),
    lifecycle_node: String((graphNode && graphNode.lifecycle_node) || stageId),
    asset_target: { ...((graphNode && graphNode.asset_target) || {}) },
    review_requirement: { ...((graphNode && graphNode.review_requirement) || {}) },
    write_set: Array.isArray((graphNode && graphNode.write_set))
      ? graphNode.write_set.slice()
      : Array.isArray(execution.write_set) ? execution.write_set.slice() : [],
    memory_contract: execution.memory_contract && typeof execution.memory_contract === 'object'
      ? { ...execution.memory_contract }
      : null,
  };
}

function resultPacketTemplateFor(task, execution, stageContract, expectedResultPacket, runnerPacketPath, memoryContext) {
  const target = stageContract.asset_target || {};
  const review = stageContract.review_requirement || {};
  return {
    schemaVersion: '1.0.0',
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    step_id: execution.step_id || execution.stage_id,
    ...stageContract,
    step_status: 'completed',
    outputs: [],
    changed_files: [],
    evidence: [],
    verification_result: review.required === true ? 'accepted' : 'pass',
    blocking_reason: '',
    next_recommendation: '进入工作流给出的下一阶段。',
    handoff_summary: '',
    checkpoint_state: { stage_id: execution.stage_id },
    output_health_result: 'pass',
    result_packet_path: expectedResultPacket,
    host_execution_mode: 'managed_runner',
    runner_packet_path: runnerPacketPath,
    memory_read_receipt: memoryContext && memoryContext.memory_read_receipt
      ? memoryContext.memory_read_receipt
      : null,
    asset_revision: { status: 'verified', asset_id: String(target.id || '') },
    review_decision: review.required === true ? 'accepted' : 'not_applicable',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'advance', target: stageContract.lifecycle_node },
    // This must be replaced with the exact files actually changed this stage.
    result_write_set: [],
  };
}

function stageInstructionFor(task, execution, stageContract) {
  const pendingFeedback = task.pending_feedback && typeof task.pending_feedback === 'object'
    ? task.pending_feedback
    : null;
  return {
    user_goal: String(task.user_goal || ''),
    scope: String(task.scope || ''),
    description: String(execution.stage_description || ''),
    required_inputs: Array.isArray(execution.required_inputs) ? execution.required_inputs.slice() : [],
    owner_module: stageContract.owner_module,
    asset_target: { ...(stageContract.asset_target || {}) },
    write_set: Array.isArray(stageContract.write_set) ? stageContract.write_set.slice() : [],
    pending_feedback: pendingFeedback ? {
      feedback_id: String(pendingFeedback.feedback_id || ''),
      section_index: Number(pendingFeedback.section_index || 0) || null,
      text: String(pendingFeedback.text || '').trim(),
    } : null,
  };
}

function buildPrompt(runnerPacketRel, expectedResultPacket, task, execution, attempt) {
  const recovery = attempt > 0
    ? '这是一次受控恢复。缩小工具调用和输出，只从最后可信断点完成当前阶段；不得重复上一轮错误。'
    : '';
  return [
    '这是已路由、已确认的非交互工作流执行。现在直接完成当前阶段。',
    `先读取 ${runnerPacketRel}，它是本轮唯一执行契约和阶段指令。`,
    `当前工作流：${task.workflow_type}；阶段：${execution.stage_id}。`,
    '不要再次调用 /novel-assistant，不要重新规划流程，不要询问用户是否执行，也不要展示候选菜单。',
    '仅执行 runner packet 的 stage_instruction，写入仅限 stage_contract.write_set。',
    '完成后必须把结构化回执写入 expected_result_packet：先从 result_packet_template 复制必填字段，再填准确的 changed_files 与 result_write_set。',
    `本轮唯一回执路径：${expectedResultPacket}。即使受阻也必须在此写入 step_status=blocked 的回执和原因。`,
    '只完成当前阶段，不越过确认边界；最终文本只给一句完成摘要，不粘贴大段正文。',
    recovery,
  ].filter(Boolean).join('\n');
}

async function runHost(root, task, execution, run, options) {
  const authority = resolveRunnerTask(root, task.workflow_id, task.task_dir);
  if (authority.status !== 'ok') {
    return {
      ...authority,
      run_id: run.runId,
      attempt: run.attempt,
      host_started: false,
    };
  }
  const budgetReservation = reserveBudget(options, task);
  const lease = refreshRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId);
  if (!lease || lease.status !== 'ok') {
    cancelBudgetReservation(options, budgetReservation);
    return {
      ...(lease || {
        status: 'blocked_runner_lease_refresh_failed',
        message: 'runner lease refresh did not return an explicit ok status',
      }),
      run_id: run.runId,
      attempt: run.attempt,
      host_started: false,
    };
  }

  const monitor = createStreamHealthMonitor({ idleTimeoutMs: options.idleTimeoutMs });
  const eventRel = `${task.task_dir}/runner-events/${run.runId}.jsonl`;
  const eventAbs = resolveInsideProject(root, eventRel);
  const startedAt = Date.now();
  const hostEvents = [];
  let stdoutBuffer = '';
  monitor.start(startedAt);

  appendJsonl(eventAbs, {
    type: 'runner_started',
    at: new Date().toISOString(),
    run_id: run.runId,
    adapter: options.adapter,
    stage_id: execution.stage_id,
    attempt: run.attempt + 1,
  });

  const child = spawn(run.invocation.command, run.invocation.args, {
    cwd: run.invocation.cwd,
    env: run.invocation.env,
    shell: false,
    stdio: run.invocation.stdio,
    detached: process.platform !== 'win32',
  });

  let terminated = false;
  let killTimer = null;
  function terminate(reason, evidence = {}) {
    if (reason) monitor.abort(reason, evidence);
    if (terminated) return;
    terminated = true;
    terminateProcessGroup(child, 'SIGTERM');
    killTimer = setTimeout(() => terminateProcessGroup(child, 'SIGKILL'), TERMINATION_GRACE_MS);
    killTimer.unref();
  }
  function consume(channel, chunk) {
    monitor.ingest(channel, chunk);
    appendJsonl(eventAbs, {
      type: 'host_output',
      at: new Date().toISOString(),
      channel,
      bytes: Buffer.byteLength(chunk),
      preview: sanitizeForArtifact(String(chunk)).slice(0, 500),
    });
    if (channel === 'stdout') {
      stdoutBuffer += String(chunk);
      const lines = stdoutBuffer.split(/\r?\n/);
      stdoutBuffer = lines.pop();
      for (const line of lines) collectHostEvent(line, hostEvents);
    }
    if (monitor.shouldAbort() && !terminated) {
      terminate();
    }
  }
  child.stdout.on('data', (chunk) => consume('stdout', chunk));
  child.stderr.on('data', (chunk) => consume('stderr', chunk));

  const idleTimer = setInterval(() => {
    if (monitor.shouldAbort() && !terminated) {
      terminate();
    }
  }, Math.max(100, Math.min(1000, Math.floor(options.idleTimeoutMs / 4))));
  idleTimer.unref();
  const heartbeatTimer = setInterval(() => {
    refreshRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId);
  }, 30 * 1000);
  heartbeatTimer.unref();

  const exit = await new Promise((resolve) => {
    child.on('error', (error) => resolve({ code: 1, signal: '', error: error.message }));
    child.on('close', (code, signal) => resolve({ code: code === null ? 1 : code, signal: signal || '', error: '' }));
  });
  clearInterval(idleTimer);
  clearInterval(heartbeatTimer);
  clearTimeout(killTimer);
  releaseRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId);
  collectHostEvent(stdoutBuffer, hostEvents);
  const health = monitor.snapshot();
  const durationMs = Date.now() - startedAt;
  const usage = normalizeHostUsage(options.adapter, hostEvents, durationMs, { outputChars: health.total_bytes || 0 });
  settleBudget(options, budgetReservation, usage);
  appendJsonl(eventAbs, {
    type: 'runner_finished',
    at: new Date().toISOString(),
    run_id: run.runId,
    exit,
    health,
    duration_ms: durationMs,
    usage,
  });
  const attemptResult = {
    run_id: run.runId,
    attempt: run.attempt,
    event_log: eventRel,
    exit,
    health,
    duration_ms: durationMs,
    usage,
  };
  attemptResult.accounting = recordCost(root, task, execution, options, attemptResult, ownerModuleFor(task, execution.stage_id));
  if (!attemptResult.accounting.ok) {
    appendJsonl(eventAbs, {
      type: 'accounting_failure',
      at: new Date().toISOString(),
      run_id: run.runId,
      error: attemptResult.accounting.error,
    });
  }
  return attemptResult;
}

function writeRunnerPacket(root, relativePath, packet) {
  const file = resolveInsideProject(root, relativePath);
  if (!file) throw new Error(`unsafe runner packet path: ${relativePath}`);
  assertNoSymlinkEscape(root, file);
  atomicWriteJson(file, packet);
}

function ownerModuleFor(task, stageId) {
  const executionOwner = ((task.stage_execution || {}).owner_module) || '';
  return executionOwner || lookupTemplateOwner(task.workflow_type, stageId) || `workflow:${task.workflow_type}:${stageId}`;
}

function lookupTemplateOwner(workflowType, stageId) {
  if (!templateOwnerCache) {
    const script = path.join(SCRIPT_DIR, 'workflow-state-machine.js');
    const result = spawnSync(process.execPath, [script, 'templates', '--json'], {
      encoding: 'utf8',
      shell: false,
      maxBuffer: 20 * 1024 * 1024,
    });
    try {
      const parsed = JSON.parse(result.stdout || '{}');
      templateOwnerCache = new Map();
      for (const template of parsed.templates || []) {
        for (const stage of template.stages || []) {
          templateOwnerCache.set(`${template.workflow_type}:${stage.stage_id}`, stage.owner_module || '');
        }
      }
    } catch {
      templateOwnerCache = new Map();
    }
  }
  return templateOwnerCache.get(`${workflowType}:${stageId}`) || '';
}

function resolveInsideProject(root, relativePath) {
  if (!relativePath) return '';
  const resolvedRoot = path.resolve(root);
  const file = path.isAbsolute(relativePath) ? path.resolve(relativePath) : path.resolve(resolvedRoot, relativePath);
  if (file === resolvedRoot || !file.startsWith(`${resolvedRoot}${path.sep}`)) return '';
  return file;
}

function assertNoSymlinkEscape(root, target) {
  const resolvedRoot = fs.realpathSync(root);
  let cursor = path.dirname(target);
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  const realParent = fs.realpathSync(cursor);
  if (realParent !== resolvedRoot && !realParent.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`runner path escapes project through symlink: ${target}`);
  }
}

function redactInvocation(invocation) {
  return {
    command: invocation.command,
    args: invocation.args,
    cwd: invocation.cwd,
    shell: false,
  };
}

module.exports = {
  assertNoSymlinkEscape,
  buildRunPreview,
  redactInvocation,
  resolveInsideProject,
  runHost,
  writeRunnerPacket,
};
