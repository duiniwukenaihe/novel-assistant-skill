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
const crypto = require('crypto');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { buildAdapterInvocation, composeStageContextGuidance } = require('./workflow-host-adapters');
const { createStreamHealthMonitor } = require('./workflow-stream-health');
const { appendJsonl, atomicWriteJson } = require('./workflow-state-store');
const { normalizeExecutionBoundary } = require('./workflow-execution-boundary');
const { classifyTaskComplexity } = require('./task-complexity-policy');
const { compactToolOutput } = require('./tool-output-compactor');
const { buildPromptEnvelope, STABLE_HARNESS_PREFIX } = require('./prompt-envelope');
const { laterCanonicalOutlineTargets } = require('./longform-scope-continuation');
const { effectiveLegacyRevalidationPolicy } = require('./legacy-revalidation-policy');
const {
  authoritativePlanningTargets,
  planningProducerForReview,
  planningReviewForProducer,
  planningRevisionPlanTemplate,
} = require('./long-planning-revision');
const { sanitizeForArtifact, terminateProcessGroup } = require('../behavior-eval');
const {
  LONG_CHAPTER_STAGES,
  assertTargetsEqual,
  expectedLongChapterWriteSet,
  validateLongChapterTargetV2,
} = require('./long-chapter-target');
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
  const stageContract = stageContractFor(root, task, execution);
  const transactionalPlanning = Boolean(
    planningReviewForProducer(execution.stage_id)
    && Array.isArray(execution.planning_targets)
    && execution.planning_targets.length > 0
  );
  if (String(execution.stage_id || '') === 'milestone_review') {
    const laterTargets = laterCanonicalOutlineTargets(root, task);
    stageContract.scope_continuation = {
      later_outline_targets: laterTargets,
      volume_acceptance_allowed: laterTargets.length === 0,
      required_next_stage: laterTargets.length > 0 ? 'detail_outline_review' : '',
    };
  }
  const estimate = (((task || {}).runtime_guard || {}).token_estimate || {});
  const executionPolicy = classifyTaskComplexity({
    workflowType: task.workflow_type,
    stageId: execution.stage_id,
    inputFiles: estimate.input_files,
    inputChars: estimate.input_chars_estimate,
    unitCount: estimate.estimated_unit_window || estimate.batch_size || 1,
    riskLevel: estimate.risk_level,
    independentDomains: execution.independent_domains || [],
    maxParallelAgents: execution.max_parallel_agents || 4,
    structuralChange: execution.structural_change,
    crossVolume: execution.cross_volume,
    failureCount: attempt,
  });
  const stageContextOk = stageContextPacket
    && stageContextPacket.status === 'assembled'
    && Boolean(stageContextPacket.packet_md);
  const stageContextBlocked = stageContextPacket && stageContextPacket.blocking === true;
  // I1: inject the collaboration advisory so managed_runner hosts surface the
  // managed-mode handoff hint when context bloats. composeStageContextGuidance
  // returns '' when there is no usable packet (fail-open), so it is safe to
  // append unconditionally — empty strings are filtered out below.
  const stageContextGuidance = stageContextOk
    ? composeStageContextGuidance(stageContextPacket)
    : '';
  const recoveryInstruction = recoveryInstructionFor(execution, attempt);
  const promptEnvelope = buildRunnerPromptEnvelope(runnerPacketRel, expectedResultPacket, task, execution, recoveryInstruction);
  const consumedArtifactIds = stageContextOk
    ? Array.from(new Set((stageContextPacket.source_files || []).map((item) => String(item.artifact_id || '')).filter(Boolean)))
    : [];
  const runnerPacket = {
    schemaVersion: '1.0.0',
    run_id: runId,
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    work_unit_id: String(execution.work_unit_id || ''),
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
    } : stageContextBlocked ? {
      status: String(stageContextPacket.status || 'blocked_long_stage_context'),
      blocking: true,
      reason: String(stageContextPacket.reason || ''),
    } : null,
    consumed_artifact_ids: consumedArtifactIds,
    attempt: attempt + 1,
    max_attempts: options.maxRetries + 1,
    recovery_instruction: recoveryInstruction,
    execution_boundary: execution.completion_boundary || 'stop_after_stage',
    // The host must echo this immutable contract in its result packet. Keeping
    // it in the runner packet makes the packet genuinely self-sufficient.
    stage_contract: stageContract,
    execution_policy: executionPolicy,
    prompt_prefix_digest: promptEnvelope.stable_prefix_digest,
    dynamic_context_digest: promptEnvelope.dynamic_context_digest,
    result_packet_template: resultPacketTemplateFor(
      task,
      execution,
      stageContract,
      expectedResultPacket,
      runnerPacketRel,
      memoryContext,
      consumedArtifactIds,
    ),
    requirements: [
      '使用 novel-assistant 入口并路由到 owner_module',
      '只执行当前 stage，不提前执行下一阶段',
      transactionalPlanning
        ? '只向 stage_contract.write_set 写入规划候选稿；不得直接写 canonical_write_set 或 expected_result_packet'
        : '只向 expected_result_packet 写入符合 result contract 的 JSON',
      '不要把完整正文或工具日志复制到最终回复',
      memoryContext.mode === 'none'
        ? '本阶段已明确不注入小说创作记忆'
        : `先读取 memory_context.packet_md，只使用与 workflow_id 和目标范围匹配的记忆`,
      ...(memoryContext && memoryContext.accepts_memory_updates === true && stageContract.review_requirement && stageContract.review_requirement.required === true ? [
        `本阶段必须审计小说记忆：若本次验收确认了新的稳定作品事实、角色状态、规划约束、规划漂移或未结承诺，在 memory_updates 中提交 1—3 条低风险 create 建议；每条必须包含 action=create、entryId、type、risk=low、reason、evidencePath、proposedContent、sourceKind=user_confirmed、accepted_artifact_id=${String(execution.stage_attempt_id || '')}、sourceRefs=[]、affects，其中 proposedContent 必须是可直接检索的非空纯文本字符串，禁止对象或数组。只要 evidence、handoff_summary 或 next_recommendation 提到上述变化，memory_updates 就不得为空。若确无新增才返回空数组，并在 memory_update_omission_reason 写明可审计理由。禁止写入菜单、路由、运行时或工作流元数据。`,
      ] : []),
      // For short-write draft stages the stage_context_packet is the single
      // allowlist. For other stages stage_context_packet is null and this
      // requirement is a no-op.
      stageContextOk
        ? `先读取 stage_context_packet.packet_md（${stageContextPacket.packet_md}），只使用包内资产写正文，不得自由搜索其他文件或读取全量 journal/result-packets/scripts`
        : '若无 stage_context_packet，按 owner_module 默认资产范围执行',
      ...(stageContract.existing_asset_policy ? [
        '这是旧项目定向恢复的既有资产复核阶段：只读取并核对既有设定与大纲；除 expected_result_packet 外不得写任何文件，不得另写定位、故事圣经或总纲复核文档，不得补写或编造未确认的全局设定。既有资产足以支撑本次 scope 时可通过；与本次范围无关的缺失不阻断。只有影响本次 scope 的矛盾或缺失才写 blocked 回执。',
      ] : []),
      ...(stageContract.result_contract === 'detail_outline_quality_v2' ? [
        '逐项审阅 stage_contract.review_targets，并在 outputs.detail_outline_quality.identities 中返回完整且不重复的身份集合；直接沿用模板预填的 workflow_id、stage_id、outline_path、outline_sha256 和 evidence，不得改名、删除或换成其他 evidence.type。',
        '替换 detail_outline_quality 模板中的结论占位值；不要创建辅助脚本计算哈希。runner 会把每项 semantic_review.findings 与 findings 对齐，并自动写入 SHA-256 与数量。',
        'semantic_review.status 只表示语义审阅是否完整执行，完成后固定写 accepted；具体通过或修订结论只写在 identity.status 与 aggregate status，禁止把 semantic_review.status 写成 revise。',
        '每条 finding.severity 只允许 blocking 或 advisory；会导致细纲必须回炉的问题写 blocking，其余建议写 advisory。',
      ] : []),
      ...(stageContract.chapter_target ? [
        '当前章节只能使用 stage_contract.chapter_target；不得从 scope、旧聊天或目录扫描推断另一章节。',
      ] : []),
      ...(String(task.workflow_type || '') === 'long_write' ? [
        'lifecycle_transition_request.action 只允许 advance、return、stay、pause，禁止 hold 等别名。通过时用 advance（target 为当前节点或 allowed_next）；阻断且回退时用 return 并严格指向 review_requirement.failure_return；留在当前节点用 stay，暂停用 pause。',
      ] : []),
      ...(planningProducerForReview(execution.stage_id) ? [
        '若本次总纲或卷纲审阅未通过，必须填写 planning_revision_plan：version 固定为 planning_revision_plan_v1，summary 写作者可读摘要，requirements 写逐条修订要求，targets 逐字复制工作流冻结目标；禁止通配符、目录扫描、推断新路径或新增文件。',
        'planning_revision_plan 只表达审阅建议；正式目标仍以工作流冻结目标为权威，二者不一致时结果必须被拒绝。失败回退只允许 return 到 review_requirement.failure_return；当前资产阶段完成时 advance 的 target 是当前 lifecycle node，阻断且不回退时 stay 在当前节点。',
      ] : []),
      ...(transactionalPlanning ? [
        `候选稿写完后必须执行 stage_contract.execution_command（${String(stageContract.execution_command || '')}）；只有 long-planning-stage-finalize.js 可提交正式规划资产、生成结果回执并按 stage_contract.success_transition 迁移`,
      ] : []),
      ...(String(execution.stage_id || '') === 'milestone_review'
        && (((stageContract || {}).scope_continuation || {}).later_outline_targets || []).length > 0 ? [
          '当前卷仍有 scope_continuation.later_outline_targets；本里程碑通过后必须进入 detail_outline_review，禁止提前进入 volume_acceptance。',
        ] : []),
      ...(String(execution.stage_id || '') === 'prose' ? [
        '若 write_set 中已有候选稿，必须先读取并按章节 Brief 续写或做最小修订，不得从头重写。正文机器检查统一由 prose_acceptance 阶段执行；本阶段禁止另跑 awk、Python、hook 或自选质量脚本。写完候选后优先写 expected_result_packet，不得为了可选复读或自检耗尽 turns。',
      ] : []),
      recoveryInstruction,
      executionPolicy.recommended_agent_count <= 1
        ? '当前阶段按单执行者路径运行，不得派发额外 Agent'
        : `当前阶段最多并行 ${executionPolicy.recommended_agent_count} 个只读 Agent，仅处理 execution_policy.parallel_domains；正式资产仍由单写入者提交`,
      // I1: collaboration-mode advisory — surface the managed_runner handoff
      // hint when the packet is valid. Empty when guidance is not applicable.
      ...(stageContextGuidance ? [stageContextGuidance] : []),
      '输出退化或工具连续失败时立即停止，不伪造完成',
    ],
  };
  const prompt = promptEnvelope.prompt;
  const invocation = buildAdapterInvocation(options.adapter, {
    projectRoot: root,
    prompt,
    runId,
    runnerPacket: runnerPacketRel,
    expectedResultPacket,
    maxBudgetUsd: options.maxBudgetUsd,
    maxTurns: options.maxTurns,
    fakeExecutable: options.fakeExecutable,
    fakeArgs: [options.fakeMode],
  });
  return { runId, runnerPacketRel, runnerPacket, invocation, attempt };
}

function stageContractFor(root, task, execution) {
  const stageId = String(execution.stage_id || task.current_stage || '');
  const graphNode = Array.isArray((task.lifecycle_graph || {}).nodes)
    ? task.lifecycle_graph.nodes.find((node) => node && node.id === stageId)
    : null;
  const declaredWriteSet = Array.isArray(execution.write_set)
    ? execution.write_set.slice()
    : Array.isArray((graphNode && graphNode.write_set)) ? graphNode.write_set.slice() : [];
  const effectiveRevalidationPolicy = effectiveLegacyRevalidationPolicy(
    task,
    stageId,
    declaredWriteSet,
    execution.canonical_write_set,
  );
  const existingAssetPolicy = effectiveRevalidationPolicy.existing_asset_policy;
  const reviewTargets = Array.isArray(execution.review_targets) && execution.review_targets.length > 0
    ? execution.review_targets.map((item) => ({ ...item }))
    : Array.isArray(task.detail_outline_review_targets) && task.detail_outline_review_targets.length > 0
      ? task.detail_outline_review_targets.map((item) => ({ ...item }))
      : recoverAcceptedDetailOutlineTargets(root, task);
  const isLongChapter = LONG_CHAPTER_STAGES.has(stageId);
  const planningProducer = planningProducerForReview(stageId);
  const planningRevisionAuthority = planningProducer
    ? authoritativePlanningTargets(root, {
        ...task,
        current_stage: stageId,
        stage_execution: execution,
      }, planningProducer)
    : { status: 'not_applicable', targets: [] };

  // Long chapter stages: frozen execution.chapter_target is the ONLY
  // source. The runner must never synthesize from task/scope/active. When
  // the frozen target is missing or incomplete, the stage contract carries
  // a blocking reason and the runner refuses to spawn.
  let chapterTarget = null;
  let chapterTargetMissing = false;
  let chapterTargetBlockingReason = '';
  if (isLongChapter) {
    const frozen = (execution.chapter_target && typeof execution.chapter_target === 'object')
      ? execution.chapter_target
      : null;
    if (!frozen || !frozen.outline_path) {
      chapterTargetMissing = true;
      chapterTargetBlockingReason = 'stage_execution.chapter_target 缺失或非对象；禁止从 active_chapter_target / scope 临时合成。';
    } else {
      const validation = validateLongChapterTargetV2(frozen, {
        projectRoot: root,
        workflowId: String((task || {}).workflow_id || ''),
      });
      if (!validation.ok) {
        chapterTargetMissing = true;
        chapterTargetBlockingReason = `stage_execution.chapter_target 不是完整 V2 目标：缺少 ${validation.missing_fields.join(', ')}。`;
      } else {
        const durableActive = (task.active_chapter_target && typeof task.active_chapter_target === 'object')
          ? task.active_chapter_target
          : null;
        const activeValidation = validateLongChapterTargetV2(durableActive, {
          projectRoot: root,
          workflowId: String((task || {}).workflow_id || ''),
        });
        const equality = activeValidation.ok ? assertTargetsEqual(durableActive, frozen) : { ok: false };
        if (!activeValidation.ok || !equality.ok) {
          chapterTargetMissing = true;
          chapterTargetBlockingReason = 'stage_execution.chapter_target 与 durable active_chapter_target 不一致或后者不完整；禁止 spawn host。';
        } else {
          chapterTarget = frozen;
        }
      }
    }
    if (!chapterTargetMissing && chapterTarget) {
      const expectedWriteSet = expectedLongChapterWriteSet(stageId, chapterTarget);
      const actualWriteSet = declaredWriteSet.map((item) => String(item || '').replace(/\\/g, '/'));
      if (JSON.stringify(actualWriteSet) !== JSON.stringify(expectedWriteSet)) {
        chapterTarget = null;
        chapterTargetMissing = true;
        chapterTargetBlockingReason = `stage_execution.write_set 与冻结 chapter_target 的 ${stageId} 精确写集不一致；禁止 spawn host。`;
      }
    }
  }
  // For chapter_brief only, accept an explicit chapter_targets array of
  // full V2 targets. The runner never synthesizes the list — it must be
  // provided complete in execution.chapter_targets.
  let chapterTargets = [];
  if (stageId === 'chapter_brief') {
    const declaredTargets = Array.isArray(execution.chapter_targets) ? execution.chapter_targets : [];
    const allTargetsValid = declaredTargets.length > 0 && declaredTargets.every((item) => {
      if (!item || typeof item !== 'object' || !item.outline_path) return false;
      return validateLongChapterTargetV2(item, {
        projectRoot: root,
        workflowId: String((task || {}).workflow_id || ''),
      }).ok;
    });
    if (allTargetsValid) {
      chapterTargets = declaredTargets.map((item) => ({ ...item }));
    } else {
      chapterTargetMissing = true;
      chapterTargetBlockingReason = 'chapter_brief 的 stage_execution.chapter_targets 缺失或包含非完整 V2 目标；禁止缩短列表后继续。';
    }
  }
  return {
    owner_module: String((graphNode && graphNode.owner_module) || ownerModuleFor(task, stageId) || ''),
    lifecycle_node: String((graphNode && graphNode.lifecycle_node) || stageId),
    asset_target: { ...((graphNode && graphNode.asset_target) || {}) },
    review_requirement: { ...((graphNode && graphNode.review_requirement) || {}) },
    write_set: effectiveRevalidationPolicy.write_set,
    canonical_write_set: effectiveRevalidationPolicy.canonical_write_set,
    planning_revision_targets: planningRevisionAuthority.status === 'ready'
      ? planningRevisionAuthority.targets.slice()
      : [],
    success_transition: planningReviewForProducer(stageId)
      ? { ...((execution || {}).success_transition || {}) }
      : null,
    result_contract: String(execution.result_contract
      || (graphNode && graphNode.result_contract)
      || (stageId === 'detail_outline_review' ? 'detail_outline_quality_v2' : '')),
    review_targets: stageId === 'detail_outline_review' ? reviewTargets : [],
    chapter_targets: chapterTargets,
    chapter_target: isLongChapter ? chapterTarget : null,
    chapter_target_missing: isLongChapter ? chapterTargetMissing : false,
    chapter_target_blocking_reason: isLongChapter ? chapterTargetBlockingReason : '',
    execution_command: String(execution.execution_command || ''),
    quality_command: String(execution.quality_command || ''),
    existing_asset_policy: existingAssetPolicy,
    memory_contract: execution.memory_contract && typeof execution.memory_contract === 'object'
      ? { ...execution.memory_contract }
      : null,
  };
}

function recoverAcceptedDetailOutlineTargets(root, task) {
  const predecessor = (Array.isArray((task || {}).stage_attempt_history) ? task.stage_attempt_history : [])
    .slice()
    .reverse()
    .find((item) => String((item || {}).stage_id || '') === 'stage_detail_outline'
      && String((item || {}).status || '') === 'completed'
      && String((item || {}).stage_attempt_id || '')
      && String((item || {}).work_unit_id || '')
      && !String((item || {}).superseded_by_attempt_id || '')
      && String((item || {}).accepted_result_packet || '')
      && String((item || {}).accepted_result_packet || '') === String((item || {}).expected_result_packet || ''));
  if (!predecessor) return [];
  const packetFile = resolveInsideProject(root, String(predecessor.accepted_result_packet || ''));
  let packet;
  try {
    packet = JSON.parse(fs.readFileSync(packetFile, 'utf8'));
  } catch (_) {
    return [];
  }
  if (String(packet.workflow_id || '') !== String(task.workflow_id || '')
      || String(packet.stage_id || '') !== 'stage_detail_outline'
      || String(packet.step_status || '') !== 'completed'
      || String(packet.verification_result || '') !== 'pass') return [];
  const candidates = [
    ...(Array.isArray(packet.result_write_set) ? packet.result_write_set : []),
    ...(Array.isArray(packet.changed_files) ? packet.changed_files : []),
  ];
  return Array.from(new Set(candidates.map((item) => String(item || '').replace(/\\/g, '/'))))
    .filter((item) => /(^|\/)细纲[^/]*\.md$/i.test(item))
    .map((outlinePath) => {
      const outlineFile = resolveInsideProject(root, outlinePath);
      try {
        if (!fs.statSync(outlineFile).isFile()) return null;
        return {
          outline_path: outlinePath,
          outline_sha256: crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex'),
        };
      } catch (_) {
        return null;
      }
    })
    .filter(Boolean);
}

function resultPacketTemplateFor(task, execution, stageContract, expectedResultPacket, runnerPacketPath, memoryContext, consumedArtifactIds, options = {}) {
  const target = stageContract.asset_target || {};
  const review = stageContract.review_requirement || {};
  const detailOutlineReview = stageContract.result_contract === 'detail_outline_quality_v2';
  const detailOutlineIdentities = detailOutlineReview
    ? stageContract.review_targets.map((item) => ({
      workflow_id: task.workflow_id,
      stage_id: execution.stage_id,
      outline_path: String((item || {}).outline_path || ''),
      outline_sha256: String((item || {}).outline_sha256 || ''),
      activated_dimensions: [],
      findings: [],
      contract_projection: [],
      execution: {
        semantic_review: {
          status: 'REPLACE_WITH_ACCEPTED',
          reviewer: 'REPLACE_WITH_REVIEWER_ID',
          findings: [],
          findings_sha256: 'REPLACE_WITH_SHA256_OF_FINDINGS_JSON',
          finding_count: 0,
        },
      },
      status: 'REPLACE_WITH_PASS_PASS_WITH_ADVISORY_REVISE_OR_OUTLINE_UNDERFILLED',
    }))
    : [];
  return {
    schemaVersion: '1.0.0',
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    step_id: execution.step_id || execution.stage_id,
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    work_unit_id: String(execution.work_unit_id || ''),
    ...stageContract,
    step_status: 'completed',
    outputs: detailOutlineReview
      ? { detail_outline_quality: { version: 'detail_outline_quality_v2', status: 'REPLACE_WITH_AGGREGATE_STATUS', identities: detailOutlineIdentities } }
      : [],
    consumed_artifact_ids: Array.isArray(consumedArtifactIds) ? consumedArtifactIds.slice() : [],
    produced_artifact_ids: [],
    changed_files: [],
    evidence: detailOutlineReview
      ? stageContract.review_targets.map((item) => ({
        type: 'detail_outline',
        path: String((item || {}).outline_path || ''),
        outline_sha256: String((item || {}).outline_sha256 || ''),
      }))
      : [],
    verification_result: review.required === true ? 'accepted' : 'pass',
    blocking_reason: '',
    next_recommendation: '进入工作流给出的下一阶段。',
    handoff_summary: '',
    checkpoint_state: { stage_id: execution.stage_id },
    output_health_result: 'pass',
    memory_updates: [],
    memory_update_omission_reason: '',
    result_packet_path: expectedResultPacket,
    host_execution_mode: String(options.hostExecutionMode || 'managed_runner'),
    runner_packet_path: runnerPacketPath,
    memory_read_receipt: memoryContext && memoryContext.memory_read_receipt
      ? memoryContext.memory_read_receipt
      : null,
    asset_revision: { status: 'verified', asset_id: String(target.id || '') },
    review_decision: review.required === true ? 'accepted' : 'not_applicable',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'advance', target: stageContract.lifecycle_node },
    ...(planningRevisionPlanTemplate(execution.stage_id)
      ? { planning_revision_plan: {
        ...planningRevisionPlanTemplate(execution.stage_id),
        targets: Array.isArray(stageContract.planning_revision_targets)
          ? stageContract.planning_revision_targets.slice()
          : [],
      } }
      : {}),
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
    resume_hint: String(execution.resume_hint || ''),
    required_inputs: Array.isArray(execution.required_inputs) ? execution.required_inputs.slice() : [],
    owner_module: stageContract.owner_module,
    asset_target: { ...(stageContract.asset_target || {}) },
    write_set: Array.isArray(stageContract.write_set) ? stageContract.write_set.slice() : [],
    existing_asset_policy: stageContract.existing_asset_policy
      ? { ...stageContract.existing_asset_policy }
      : null,
    pending_feedback: pendingFeedback ? {
      feedback_id: String(pendingFeedback.feedback_id || ''),
      section_index: Number(pendingFeedback.section_index || 0) || null,
      text: String(pendingFeedback.text || '').trim(),
    } : null,
  };
}

function recoveryInstructionFor(execution, attempt) {
  if (attempt <= 0) return '';
  if (String((execution || {}).stage_id || '') === 'prose') {
    return '这是正文受控恢复：先复用 write_set 中已有候选，只补未完成处，不得从头重写；不要运行机械质量门，完成最小核对后优先补齐 expected_result_packet。';
  }
  return '这是一次受控恢复。缩小工具调用和输出，只从最后可信断点完成当前阶段；不得重复上一轮错误。';
}

function buildRunnerPromptEnvelope(runnerPacketRel, expectedResultPacket, task, execution, recoveryInstruction) {
  return buildPromptEnvelope([
    `先读取 ${runnerPacketRel}，它是本轮唯一执行契约和阶段指令。`,
    `当前工作流：${task.workflow_type}；阶段：${execution.stage_id}。`,
    '仅执行 runner packet 的 stage_instruction，写入仅限 stage_contract.write_set。',
    '完成后必须把结构化回执写入 expected_result_packet：先从 result_packet_template 复制必填字段，再填准确的 changed_files 与 result_write_set。',
    `本轮唯一回执路径：${expectedResultPacket}。即使受阻也必须在此写入 step_status=blocked 的回执和原因。`,
    '只完成当前阶段，不越过确认边界；最终文本只给一句完成摘要，不粘贴大段正文。',
    recoveryInstruction,
  ]);
}

async function runHost(root, task, execution, run, options) {
  const stageContract = run.runnerPacket && run.runnerPacket.stage_contract ? run.runnerPacket.stage_contract : {};
  const stageContext = run.runnerPacket && run.runnerPacket.stage_context_packet
    ? run.runnerPacket.stage_context_packet
    : null;
  if (stageContext && stageContext.blocking === true) {
    return {
      status: String(stageContext.status || 'blocked_long_stage_context'),
      message: String(stageContext.reason || '长篇章节上下文包阻断，禁止 spawn host。'),
      run_id: run.runId,
      attempt: run.attempt,
      host_started: false,
    };
  }
  if (stageContract.chapter_target_missing === true) {
    return {
      status: 'blocked_chapter_target_frozen_missing',
      message: String(stageContract.chapter_target_blocking_reason || '长篇章节阶段缺少冻结的 chapter_target，禁止 spawn host。'),
      run_id: run.runId,
      attempt: run.attempt,
      host_started: false,
    };
  }
  if (LONG_CHAPTER_STAGES.has(String(execution.stage_id || ''))) {
    try {
      for (const relativePath of Array.isArray(stageContract.write_set) ? stageContract.write_set : []) {
        const targetPath = resolveInsideProject(root, String(relativePath || ''));
        if (!targetPath) throw new Error(`unsafe long chapter write path: ${relativePath}`);
        assertNoSymlinkEscape(root, targetPath);
      }
    } catch (error) {
      return {
        status: 'blocked_long_chapter_write_path_unsafe',
        message: String(error && error.message ? error.message : error),
        run_id: run.runId,
        attempt: run.attempt,
        host_started: false,
      };
    }
  }
  const authority = resolveRunnerTask(root, task.workflow_id, task.task_dir);
  if (authority.status !== 'ok') {
    return {
      ...authority,
      run_id: run.runId,
      attempt: run.attempt,
      host_started: false,
    };
  }
  let budgetReservation;
  try {
    budgetReservation = reserveBudget(options, task);
  } catch (error) {
    if (error && error.status === 'blocked_retry_budget_exhausted') {
      return {
        status: error.status,
        message: error.message,
        budget: error.budget || null,
        run_id: run.runId,
        attempt: run.attempt,
        host_started: false,
      };
    }
    throw error;
  }
  const runnerBinding = {
    runner_packet_path: String(run.runnerPacketRel || ''),
    expected_result_packet: String((run.runnerPacket || {}).expected_result_packet
      || execution.expected_result_packet || ''),
  };
  const lease = refreshRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId, runnerBinding);
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
  const outputBaseRel = `${task.task_dir}/runner-output/${run.runId}`;
  const stdoutRel = `${outputBaseRel}.stdout.log`;
  const stderrRel = `${outputBaseRel}.stderr.log`;
  const summaryRel = `${outputBaseRel}.summary.json`;
  const stdoutAbs = resolveInsideProject(root, stdoutRel);
  const stderrAbs = resolveInsideProject(root, stderrRel);
  const summaryAbs = resolveInsideProject(root, summaryRel);
  fs.mkdirSync(path.dirname(stdoutAbs), { recursive: true });
  fs.writeFileSync(stdoutAbs, '', 'utf8');
  fs.writeFileSync(stderrAbs, '', 'utf8');
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
    fs.appendFileSync(channel === 'stdout' ? stdoutAbs : stderrAbs, chunk);
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
    refreshRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId, runnerBinding);
  }, 30 * 1000);
  heartbeatTimer.unref();

  const exit = await new Promise((resolve) => {
    child.on('error', (error) => resolve({ code: 1, signal: '', error: error.message }));
    child.on('close', (code, signal) => resolve({ code: code === null ? 1 : code, signal: signal || '', error: '' }));
  });
  clearInterval(idleTimer);
  clearInterval(heartbeatTimer);
  clearTimeout(killTimer);
  releaseRunnerLease(root, task.workflow_id, task.task_dir, execution.stage_id, run.runId, runnerBinding);
  collectHostEvent(stdoutBuffer, hostEvents);
  const health = monitor.snapshot();
  const durationMs = Date.now() - startedAt;
  const rawStdout = fs.readFileSync(stdoutAbs, 'utf8');
  const rawStderr = fs.readFileSync(stderrAbs, 'utf8');
  const toolOutputSummary = {
    ...compactToolOutput(`${rawStdout}${rawStderr ? `\n${rawStderr}` : ''}`, { kind: 'host' }),
    raw_stdout: stdoutRel,
    raw_stderr: stderrRel,
  };
  atomicWriteJson(summaryAbs, toolOutputSummary);
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
    tool_output_summary: { ...toolOutputSummary, path: summaryRel },
    prompt_envelope: {
      stable_prefix_digest: run.runnerPacket.prompt_prefix_digest,
      dynamic_context_digest: run.runnerPacket.dynamic_context_digest,
    },
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

function writeDeterministicLongProseReceipt(root, task, execution, run, attemptResult) {
  if (String((task || {}).workflow_type || '') !== 'long_write'
      || String((execution || {}).stage_id || '') !== 'prose') return { status: 'not_applicable' };
  const health = ((attemptResult || {}).health || {});
  const healthyMissingReceipt = String(health.status || '') === 'healthy';
  const recoverableMaxTurns = String(health.stop_reason || '') === 'max_turns_exhausted';
  if (!healthyMissingReceipt && !recoverableMaxTurns) return { status: 'not_applicable' };
  const runnerPacket = ((run || {}).runnerPacket || {});
  const contract = (runnerPacket.stage_contract && typeof runnerPacket.stage_contract === 'object')
    ? runnerPacket.stage_contract : {};
  const target = (contract.chapter_target && typeof contract.chapter_target === 'object')
    ? contract.chapter_target : null;
  const candidate = String((target || {}).candidate_draft_path || '').replace(/\\/g, '/');
  const writeSet = Array.isArray(contract.write_set)
    ? contract.write_set.map((item) => String(item || '').replace(/\\/g, '/')) : [];
  if (!candidate || writeSet.length !== 1 || writeSet[0] !== candidate) return { status: 'not_applicable' };
  const candidateFile = resolveInsideProject(root, candidate);
  const resultFile = resolveInsideProject(root, String((execution || {}).expected_result_packet || ''));
  if (!candidateFile || !resultFile || !fs.existsSync(candidateFile) || !fs.statSync(candidateFile).isFile()
      || !fs.readFileSync(candidateFile, 'utf8').trim()) return { status: 'not_applicable' };
  assertNoSymlinkEscape(root, candidateFile);
  assertNoSymlinkEscape(root, resultFile);
  const currentDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(candidateFile)).digest('hex')}`;
  const baseline = String((((execution || {}).write_snapshot || {}).files || {})[candidate] || '');
  const changedFiles = !baseline || baseline !== currentDigest ? [candidate] : [];
  const template = runnerPacket.result_packet_template;
  if (!template || typeof template !== 'object' || Array.isArray(template)) return { status: 'not_applicable' };
  const packet = JSON.parse(JSON.stringify(template));
  packet.step_status = 'completed';
  packet.outputs = [candidate];
  packet.changed_files = changedFiles;
  packet.result_write_set = changedFiles;
  packet.evidence = [{ kind: 'candidate_draft', path: candidate, sha256: currentDigest.slice('sha256:'.length) }];
  packet.verification_result = 'pass';
  packet.blocking_findings = [];
  packet.next_recommendation = '进入当前章正文验收。';
  packet.handoff_summary = '当前章候选已写入冻结候选路径，由运行器确定性补齐阶段回执。';
  packet.checkpoint_state = { stage_id: 'prose', candidate_draft_path: candidate };
  packet.lifecycle_transition_request = { action: 'advance', target: 'prose' };
  packet.receipt_origin = 'deterministic_long_prose_finalize';
  packet.output_health_result = 'pass';
  atomicWriteJson(resultFile, packet);
  return { status: 'written', result_packet: String(execution.expected_result_packet || ''), changed_files: changedFiles };
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
  if (fs.existsSync(target)) {
    const realTarget = fs.realpathSync(target);
    if (realTarget !== resolvedRoot && !realTarget.startsWith(`${resolvedRoot}${path.sep}`)) {
      throw new Error(`runner path escapes project through symlink: ${target}`);
    }
  }
}

function normalizeManagedResultPacket(root, task, execution, resultFile) {
  if (!resultFile || !fs.existsSync(resultFile) || !fs.statSync(resultFile).isFile()) return { status: 'not_applicable' };
  let packet;
  try { packet = JSON.parse(fs.readFileSync(resultFile, 'utf8')); } catch (_) { return { status: 'not_applicable' }; }
  if (String(packet.workflow_id || '') !== String((task || {}).workflow_id || '')
      || String(packet.stage_id || '') !== String((execution || {}).stage_id || '')) return { status: 'not_applicable' };
  const normalizedFields = ['workflow_id', 'stage_id', 'stage_attempt_id', 'work_unit_id', 'result_packet_path', 'host_execution_mode'];
  packet.workflow_id = String(task.workflow_id || '');
  packet.stage_id = String(execution.stage_id || '');
  packet.stage_attempt_id = String(execution.stage_attempt_id || '');
  packet.work_unit_id = String(execution.work_unit_id || '');
  packet.result_packet_path = String(execution.expected_result_packet || '');
  packet.host_execution_mode = 'managed_runner';
  const transition = packet.lifecycle_transition_request;
  if (transition && typeof transition === 'object' && !Array.isArray(transition)
      && String(transition.action || '').trim().toLowerCase() === 'hold') {
    const target = String(transition.target || '').trim();
    const failureReturn = String((((execution || {}).review_requirement || {}).failure_return) || '');
    const currentStage = String((execution || {}).stage_id || '');
    if (failureReturn && target === failureReturn) {
      packet.lifecycle_transition_request = { ...transition, action: 'return', target: failureReturn };
      normalizedFields.push('lifecycle_transition_request.action');
    } else if (!target || target === currentStage) {
      packet.lifecycle_transition_request = { ...transition, action: 'stay', target: currentStage };
      normalizedFields.push('lifecycle_transition_request.action');
    }
  }
  if (String((execution || {}).stage_id || '') === 'milestone_review'
      && String((((packet || {}).lifecycle_transition_request || {}).action) || '').trim().toLowerCase() === 'advance'
      && String((((packet || {}).lifecycle_transition_request || {}).target) || '') === 'volume_acceptance') {
    const laterTargets = laterCanonicalOutlineTargets(root, task);
    if (laterTargets.length > 0) {
      packet.lifecycle_transition_request = { action: 'advance', target: 'detail_outline_review' };
      packet.next_stage_id = 'detail_outline_review';
      packet.detail_outline_review_targets = laterTargets;
      normalizedFields.push('premature_volume_acceptance');
    }
  }
  if (Array.isArray(packet.memory_updates)) {
    let normalizedMemoryContent = false;
    let normalizedMemoryType = false;
    const typeAliases = {
      accepted_fact: 'fact',
      active_promise: 'hook',
      planning_constraint: 'rule',
      character_state: 'character',
    };
    packet.memory_updates = packet.memory_updates.map((update) => {
      if (!update || typeof update !== 'object') return update;
      const normalized = { ...update };
      const alias = typeAliases[String(update.type || '').trim().toLowerCase()];
      if (alias) {
        normalized.type = alias;
        normalizedMemoryType = true;
      }
      if (update.proposedContent !== null && typeof update.proposedContent === 'object') {
        normalized.proposedContent = JSON.stringify(update.proposedContent);
        normalizedMemoryContent = true;
      }
      return normalized;
    });
    if (normalizedMemoryContent) normalizedFields.push('memory_updates.proposedContent');
    if (normalizedMemoryType) normalizedFields.push('memory_updates.type');
  }
  if (execution.chapter_target && typeof execution.chapter_target === 'object') {
    packet.chapter_target = JSON.parse(JSON.stringify(execution.chapter_target));
    normalizedFields.push('chapter_target');
  }
  if (Array.isArray(execution.chapter_targets)) {
    packet.chapter_targets = JSON.parse(JSON.stringify(execution.chapter_targets));
    normalizedFields.push('chapter_targets');
  }
  let expectedReceipt = ((((execution || {}).memory_context || {}).memory_read_receipt) || null);
  let trustedResultTemplate = null;
  const runnerFile = resolveInsideProject(root, String(packet.runner_packet_path || ''));
  if (runnerFile && fs.existsSync(runnerFile) && fs.statSync(runnerFile).isFile()) {
    try {
      assertNoSymlinkEscape(root, runnerFile);
      const runner = JSON.parse(fs.readFileSync(runnerFile, 'utf8'));
      if (String(runner.workflow_id || '') === String(task.workflow_id || '')
          && String(runner.stage_id || '') === String(execution.stage_id || '')
          && String(runner.expected_result_packet || '') === String(execution.expected_result_packet || '')) {
        expectedReceipt = ((((runner || {}).memory_context || {}).memory_read_receipt) || expectedReceipt);
        trustedResultTemplate = runner.result_packet_template && typeof runner.result_packet_template === 'object'
          ? runner.result_packet_template
          : null;
      }
    } catch (_) {
      // The state machine remains the final verifier; a malformed runner
      // packet must not become a source of normalized identity fields.
    }
  }
  if (expectedReceipt) {
    packet.memory_read_receipt = JSON.parse(JSON.stringify(expectedReceipt));
    normalizedFields.push('memory_read_receipt');
  }
  if (String((task || {}).workflow_type || '') === 'long_write' && trustedResultTemplate) {
    for (const field of ['asset_revision', 'review_decision', 'downstream_effects']) {
      if ((packet[field] === undefined || packet[field] === null) && trustedResultTemplate[field] !== undefined) {
        packet[field] = JSON.parse(JSON.stringify(trustedResultTemplate[field]));
        normalizedFields.push(field);
      }
    }
  }
  const normalizePathItem = (item) => {
    if (typeof item === 'string') return item;
    if (item && typeof item === 'object' && !Array.isArray(item) && typeof item.path === 'string') return item.path;
    return '';
  };
  const canNormalizePathList = (items) => Array.isArray(items) && items.every((item) => normalizePathItem(item).trim());
  const normalizePathList = (items) => Array.from(new Set((Array.isArray(items) ? items : [])
    .map((item) => normalizePathItem(item).replace(/\\/g, '/').trim())
    .filter(Boolean))).sort();
  const changedFiles = normalizePathList(packet.changed_files);
  const authorizedWriteSet = normalizePathList((execution || {}).write_set);
  const declaredWriteSet = normalizePathList(packet.result_write_set);
  if (canNormalizePathList(packet.changed_files)
      && JSON.stringify(packet.changed_files) !== JSON.stringify(changedFiles)) {
    packet.changed_files = changedFiles;
    normalizedFields.push('changed_files');
  }
  if (canNormalizePathList(packet.result_write_set)
      && JSON.stringify(packet.result_write_set) !== JSON.stringify(declaredWriteSet)) {
    packet.result_write_set = declaredWriteSet;
    normalizedFields.push('result_write_set');
  }
  const selfResultPath = String((execution || {}).expected_result_packet || '').replace(/\\/g, '/');
  const exactAuthorizedLongProseChange = String((task || {}).workflow_type || '') === 'long_write'
    && String((execution || {}).stage_id || '') === 'prose'
    && changedFiles.length > 0
    && JSON.stringify(changedFiles) === JSON.stringify(authorizedWriteSet)
    && (declaredWriteSet.length === 0
      || (declaredWriteSet.length === 1 && declaredWriteSet[0] === selfResultPath));
  if (exactAuthorizedLongProseChange) {
    packet.result_write_set = [...changedFiles];
    normalizedFields.push('result_write_set');
  }
  if (String((execution || {}).result_contract || '') !== 'detail_outline_quality_v2') {
    packet.contract_normalization = { status: 'immutable_fields_restored', fields: normalizedFields };
    atomicWriteJson(resultFile, packet);
    return { status: 'normalized' };
  }
  const quality = (((packet || {}).outputs || {}).detail_outline_quality) || {};
  const identities = Array.isArray(quality.identities) ? quality.identities : [];
  const targets = Array.isArray((execution || {}).review_targets) ? execution.review_targets : [];
  const actualPaths = identities.map((item) => String((item || {}).outline_path || ''));
  const expectedPaths = targets.map((item) => String((item || {}).outline_path || ''));
  if (identities.length !== targets.length
      || new Set(actualPaths).size !== actualPaths.length
      || expectedPaths.some((outlinePath) => !actualPaths.includes(outlinePath))) return { status: 'not_applicable' };
  const allowedStatuses = new Set(['pass', 'pass_with_advisory', 'revise', 'outline_underfilled']);
  let normalizedFindingSeverity = false;
  const normalizeFindings = (items) => (Array.isArray(items) ? items : []).map((finding) => {
    if (!finding || typeof finding !== 'object') return finding;
    const raw = String(finding.severity || '').trim();
    const key = raw.toLowerCase();
    const severity = ['s0', 's1', 's2'].includes(key)
      ? 'blocking'
      : ['s3', 's4'].includes(key) ? 'advisory' : raw;
    if (severity !== raw) normalizedFindingSeverity = true;
    return severity === raw ? finding : { ...finding, severity };
  });
  const normalizedIdentities = targets.map((target) => {
    const identity = identities.find((item) => String((item || {}).outline_path || '') === String(target.outline_path || ''));
    const status = String((identity || {}).status || '').toLowerCase();
    const semantic = ((((identity || {}).execution || {}).semantic_review) || {});
    const semanticStatus = String(semantic.status || '').toLowerCase();
    const normalizedSemanticStatus = ['accepted', 'completed', 'pass', 'pass_with_advisory', 'revise', 'outline_underfilled'].includes(semanticStatus)
      ? 'accepted'
      : semanticStatus;
    if (normalizedSemanticStatus !== semanticStatus) normalizedFields.push('semantic_review.status');
    const findings = normalizeFindings((identity || {}).findings);
    const findingsSha256 = crypto.createHash('sha256').update(JSON.stringify(findings), 'utf8').digest('hex');
    return {
      ...identity,
      workflow_id: String(task.workflow_id || ''),
      stage_id: String(execution.stage_id || ''),
      outline_path: String(target.outline_path || ''),
      outline_sha256: String(target.outline_sha256 || ''),
      status: allowedStatuses.has(status) ? status : String((identity || {}).status || ''),
      findings,
      execution: {
        ...((identity || {}).execution || {}),
        semantic_review: {
          ...semantic,
          status: normalizedSemanticStatus,
          findings,
          findings_sha256: findingsSha256,
          finding_count: findings.length,
        },
      },
    };
  });
  if (normalizedFindingSeverity) normalizedFields.push('findings.severity');
  const aggregateStatus = String(quality.status || '').toLowerCase();
  const otherEvidence = (Array.isArray(packet.evidence) ? packet.evidence : [])
    .filter((item) => String((item || {}).type || '') !== 'detail_outline');
  packet.outputs = {
    ...(packet.outputs || {}),
    detail_outline_quality: {
      ...quality,
      status: allowedStatuses.has(aggregateStatus) ? aggregateStatus : String(quality.status || ''),
      identities: normalizedIdentities,
    },
  };
  packet.evidence = [
    ...targets.map((target) => ({
      type: 'detail_outline',
      path: String(target.outline_path || ''),
      outline_sha256: String(target.outline_sha256 || ''),
    })),
    ...otherEvidence,
  ];
  packet.contract_normalization = {
    status: 'immutable_fields_restored',
    fields: [...normalizedFields, 'outline_path', 'outline_sha256', 'evidence.detail_outline', 'semantic_review.integrity', 'enum_case'],
  };
  atomicWriteJson(resultFile, packet);
  return { status: 'normalized' };
}

function classifyExistingManagedResultUnit(task, execution, resultFile) {
  if (!resultFile || !fs.existsSync(resultFile) || !fs.statSync(resultFile).isFile()) {
    return { status: 'current_or_indeterminate' };
  }
  let packet;
  try { packet = JSON.parse(fs.readFileSync(resultFile, 'utf8')); } catch (_) {
    return { status: 'current_or_indeterminate' };
  }
  if (String((task || {}).workflow_type || '') !== 'long_write'
      || String(packet.workflow_id || '') !== String((task || {}).workflow_id || '')
      || String(packet.stage_id || '') !== String((execution || {}).stage_id || '')) {
    return { status: 'current_or_indeterminate' };
  }
  const currentAttemptId = String((execution || {}).stage_attempt_id || '');
  const packetAttemptId = String(packet.stage_attempt_id || '');
  const currentWorkUnitId = String((execution || {}).work_unit_id || '');
  const packetWorkUnitId = String(packet.work_unit_id || '');
  if (currentAttemptId && packetAttemptId && packetAttemptId !== currentAttemptId) {
    return { status: 'stale_stage_attempt', existing_stage_attempt_id: packetAttemptId, current_stage_attempt_id: currentAttemptId };
  }
  if (currentWorkUnitId && packetWorkUnitId && packetWorkUnitId !== currentWorkUnitId) {
    return {
      status: 'stale_stage_attempt',
      existing_stage_attempt_id: packetAttemptId,
      current_stage_attempt_id: currentAttemptId,
      existing_work_unit_id: packetWorkUnitId,
      current_work_unit_id: currentWorkUnitId,
    };
  }
  const existing = packet.chapter_target && typeof packet.chapter_target === 'object'
    ? packet.chapter_target : null;
  const current = execution.chapter_target && typeof execution.chapter_target === 'object'
    ? execution.chapter_target : null;
  const existingTargetId = String((existing || {}).target_id || '');
  const currentTargetId = String((current || {}).target_id || '');
  if (existingTargetId && currentTargetId && existingTargetId !== currentTargetId) {
    const identityFields = ['outline_path', 'contract_path', 'draft_path', 'candidate_draft_path'];
    const comparable = identityFields.filter((field) => String(existing[field] || '') && String(current[field] || ''));
    if (comparable.some((field) => String(existing[field]) !== String(current[field]))) {
      return {
        status: 'stale_long_chapter_unit',
        existing_target_id: existingTargetId,
        current_target_id: currentTargetId,
      };
    }
  }
  if (currentAttemptId && !packetAttemptId) {
    const expectedResult = String((execution || {}).expected_result_packet || '');
    const terminalAttemptStatuses = new Set(['completed', 'failed', 'rejected', 'blocked', 'superseded', 'cancelled']);
    const prior = [...(Array.isArray((task || {}).stage_attempt_history) ? task.stage_attempt_history : [])]
      .reverse()
      .find((item) => String((item || {}).stage_id || '') === String((execution || {}).stage_id || '')
        && terminalAttemptStatuses.has(String((item || {}).status || ''))
        && [item.expected_result_packet, item.accepted_result_packet, item.failed_result_packet, item.result_packet]
          .some((value) => String(value || '') === expectedResult));
    const priorAttemptId = String((prior || {}).stage_attempt_id || '');
    if (priorAttemptId && priorAttemptId !== currentAttemptId) {
      return { status: 'stale_stage_attempt', existing_stage_attempt_id: priorAttemptId, current_stage_attempt_id: currentAttemptId };
    }
    return { status: 'indeterminate_long_write_result' };
  }
  if (currentWorkUnitId && !packetWorkUnitId) return { status: 'indeterminate_long_write_result' };
  if ((currentAttemptId && packetAttemptId) || (currentWorkUnitId && packetWorkUnitId)) {
    return { status: 'current_or_indeterminate' };
  }
  return { status: 'indeterminate_long_write_result' };
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
  STABLE_HARNESS_PREFIX,
  assertNoSymlinkEscape,
  buildRunPreview,
  classifyExistingManagedResultUnit,
  normalizeManagedResultPacket,
  redactInvocation,
  resultPacketTemplateFor,
  resolveInsideProject,
  runHost,
  stageContractFor,
  writeDeterministicLongProseReceipt,
  writeRunnerPacket,
};
