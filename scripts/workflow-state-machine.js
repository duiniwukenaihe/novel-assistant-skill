#!/usr/bin/env node
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const path = require('path');
const {
  acquireProjectLock,
  appendJsonl: appendJsonlRecord,
  atomicWriteJson,
  atomicWriteText,
  createWorkflowId,
  mutateTask,
  validateTaskState,
} = require('./lib/workflow-state-store');
const { readFocusedTask, resolveTaskAuthority, writeFocusPointer } = require('./lib/workflow-task-authority');
const {
  buildReviewBatchState,
  completeReviewBatch,
  currentReviewBatch,
  reviewBatchResultPacket,
} = require('./lib/review-batch-state');
const {
  writeReviewPlan,
  legacyReadOnlyBlock,
} = require('./lib/review-plan-contract');
const { buildEvidenceMap } = require('./lib/review-evidence');
const { buildSourceIdentity } = require('./lib/review-batch-planner');
const {
  resolveReviewTarget,
  reviewEvidencePolicy,
  validateAssetDependencyEvidenceReceipt,
} = require('./lib/review-target-policy');
const {
  isCanonicalTarget,
  loadCanonicalWritePolicy,
  normalizeTargets,
} = require('./lib/canonical-write-policy');
const {
  acceptValidatedStageWrites,
  auditCanonicalWrites,
  captureCanonicalBaseline,
} = require('./lib/canonical-write-audit');
const {
  normalizeMigrationSource,
  scanWorkflowMigrations,
  writeMigrationInventory,
} = require('./lib/workflow-legacy-migration');
const {
  ensureTaskFamily,
  readTaskFamily,
  resolveTaskRelationship,
  claimFamilyWriter,
} = require('./lib/task-family-store');
const {
  LIFECYCLE_NODES,
  validateLifecycleTransition,
} = require('./lib/longform-lifecycle');
const {
  invalidateDownstream,
  buildReplanActions,
} = require('./lib/lifecycle-impact');
const { normalizeExecutionBoundary } = require('./lib/workflow-execution-boundary');
const {
  BASE_TEMPLATES,
  LONG_WRITE_RESULT_FIELDS,
  RESULT_CONTRACT_V2_FIELDS,
  buildEffectiveTemplates,
  resolveTemplateForTask,
  unitLifecycle,
} = require('./lib/workflow-template-registry');
const { buildStageContextPacket } = require('./lib/workflow-stage-context-packet');
const { buildShortSectionOutlineContract } = require('./lib/short-section-outline-contract');
const { buildLongStageContextPacket } = require('./lib/long-stage-context-packet');
const {
  buildInitialReviewPlan,
  buildReviewAdvanceSummary,
  expectedReviewBatchResultPacket,
  parseNumericScope,
  protocolV2ReviewBatchResultPacket,
  reviewBatchContinuation,
  shellQuote,
  terminalReviewBatch,
  validateTaskReviewPlan,
} = require('./lib/workflow-review-lifecycle');
const {
  buildCompletionPendingAction,
  buildPendingAction,
  buildReviewBatchPendingAction,
  buildReviewBatchReacceptancePendingAction,
  buildShortDraftPendingAction,
  buildShortRevisionQueueProgress,
  buildShortRevisionTaskOverview,
  buildWorkflowTaskOverview,
  buildShortSectionDecisionPendingAction,
  decoratePendingAction,
  normalizeRecommendations,
  normalizeSelectedAction,
  renderPendingActionText,
} = require('./lib/workflow-action-renderer');
const {
  validateResultPacketUnitBinding,
} = require('./lib/workflow-result-packet-identity');
const {
  PUBLIC_COMMANDS,
  dispatchCommand,
  isMutatingCommand,
  isPublicCommand,
} = require('./lib/workflow-command-registry');
const {
  currentUnitRole,
  findStage,
  nextStopReason,
  shouldStopBeforeStage,
  trustedArtifactFromResult,
} = require('./lib/workflow-lifecycle-service');
const { createWorkflowTransitionService, validateLifecycleTransitionRequest } = require('./lib/workflow-transition-service');
const { createWorkflowRecoveryService } = require('./lib/workflow-recovery-service');
const { renderTaskMarkdown } = require('./lib/workflow-user-menu');
const { checkShortProseEntry } = require('./lib/short-prose-entry-guard');
const { checkBriefFreshness, writeBriefFreshnessSnapshot } = require('./lib/short-brief-freshness');
const { checkShortMemoryStage } = require('./lib/short-memory-stage-policy');
const { resolveShortFeedbackPatch } = require('./lib/short-feedback-impact-policy');
const { inferShortSectionIndex, resolvePlannedSectionCount, resolveShortPlanProgress } = require('./lib/short-workflow-state');
const { validateShortSectionAcceptanceProof } = require('./lib/short-section-acceptance-proof');
const { inspectChapter } = require('./lib/chapter-commit-store');
const { memoryProjectionAdvanceDecision, projectAcceptedMemoryUpdates } = require('./lib/workflow-memory-updates');
const { validateMemoryReadReceipt } = require('./lib/memory-query-contract');
const { prepareMemoryContext } = require('./lib/workflow-memory-context');
const { resolveExecutionMemoryPolicy } = require('./lib/workflow-memory-policy');
const { StoryMemoryRepository } = require('./lib/story-memory-repository');
const { recordAcceptedShortFeedback } = require('./lib/short-feedback-outbox');
const { acceptShortPlanningDecision, projectAcceptedShortPlanningFeedback } = require('./lib/short-planning-memory');
const {
  initializeShortFeedbackRevisionQueue,
  activeShortFeedbackRevision,
  currentShortFeedbackRevisionSection,
  acceptShortFeedbackRevisionSection,
  reconcileShortRevisionQueueWithTitleLock,
} = require('./lib/short-feedback-revision-queue');
const { discardShortFeedbackItem, enqueueShortFeedback, recordShortFeedbackReclassification, resolveShortFeedback } = require('./lib/short-feedback-working-memory');
const { validateEditorialReviewCard, attachEvidenceRuntime } = require('./lib/short-story-editorial-review');

const SCHEMA_VERSION = '1.0.0';
const REVIEW_EVIDENCE_PROTOCOL_VERSION = '2.0.0';
const WORKFLOW_SESSION_LEASE_MS = 20 * 60 * 1000;
const SHORT_EXECUTABLE_STAGE_CONTRACTS = new Set([
  'section_plan_lock', 'short_structure_impact_audit', 'hook_retention_gate', 'hook_value_gate',
  'first_section_brief', 'section_brief', 'next_section_brief',
  'draft_first_section', 'draft_section', 'draft_next_section',
  'section_machine_gate', 'section_repair_loop', 'quality_gate', 'story_value_gate',
  'section_accept_anchor', 'full_story_assembly', 'full_story_review',
  'short_deslop', 'deslop', 'final_check',
]);
const LONG_EXECUTABLE_STAGE_CONTRACTS = new Set(['chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit']);
const USAGE = `Usage: node scripts/workflow-state-machine.js <${PUBLIC_COMMANDS.join('|')}> [options]

Commands:
  templates [--private-registry-root <dir>] [--no-private-registry] --json
  create --workflow-type <type> --project-root <book-dir> [--scope <scope>] [--user-goal <goal>] [--host-context-chars <chars>] [--runtime-context-chars <chars>] [--private-registry-root <dir>] --json
  inspect --project-root <book-dir> [--private-registry-root <dir>] --json
  task-overview --project-root <book-dir> [--private-registry-root <dir>] --json
  resolve-action --project-root <book-dir> --input <number-or-text> [--pending-action-id <id> --visible-choice-hash <hash> --state-version <version> --book-root <book-dir>] [--private-registry-root <dir>] --json
  apply-result --project-root <book-dir> --workflow-id <id> --result <file> [--private-registry-root <dir>] --json
  next-candidates --project-root <book-dir> [--private-registry-root <dir>] --json
  switch-intent --workflow-type <type> --project-root <book-dir> [--scope <scope>] [--user-goal <goal>] [--reason <reason>] [--private-registry-root <dir>] --json
  activate --workflow-id <id> --project-root <book-dir> [--compact] [--private-registry-root <dir>] --json
  migrate-legacy --project-root <book-dir> --source <oh-story|novel-assistant-previous> [--write --workflow-id <id> [--confirm]] [--json]
  migrate-longform-successor --project-root <book-dir> --workflow-id <id> --source <oh-story|novel-assistant-previous> --confirm [--json]
  reset-incompatible-review-batches --project-root <book-dir> --workflow-id <id> --confirm [--json]
  continue-review-with-legacy-evidence --project-root <book-dir> --workflow-id <id> --confirm [--json]
  restore-incomplete-workflow --project-root <book-dir> --workflow-id <id> --confirm [--json]
  refresh-short-title-lock --project-root <book-dir> --workflow-id <id> [--json]
  resume-pending-short-feedback --project-root <book-dir> --workflow-id <id> [--json]
  discard-short-feedback-item --project-root <book-dir> --workflow-id <id> --feedback-id <id> --confirm [--json]
  reclassify-short-feedback-item --project-root <book-dir> --workflow-id <id> --feedback-id <id> [--plan-id <id>] --confirm [--json]
  migrate-short-lean-workflow --project-root <book-dir> --workflow-id <id> [--confirm] [--json]
  reconcile-runtime --project-root <book-dir> --workflow-id <id> --session-id <id> [--takeover --confirm] [--json]`;

let ACTIVE_TEMPLATES = null;
let ACTIVE_REGISTRIES = [];
const WORKFLOW_RECOVERY = createWorkflowRecoveryService({
  exists: fs.existsSync,
  resolveInsideProject,
  durableTaskSnapshotPath,
});
const WORKFLOW_TRANSITIONS = createWorkflowTransitionService({
  findStage,
  currentUnitRole,
  unitLifecycle,
  validateLifecycleTransition,
});

const LONG_WRITE_ACCEPTED_REVIEW_RESULTS = new Set(['accepted', 'approved', 'pass', 'passed']);
const LONG_WRITE_NODE_STATUSES = new Set(['missing', 'draft', 'needs_review', 'accepted', 'needs_recheck', 'invalidated']);
function parseArgs(argv) {
  const rawCommand = argv[2] || '';
  const implicitCommand = !rawCommand || rawCommand.startsWith('--');
  const command = implicitCommand ? 'next-candidates' : rawCommand;
  const args = { command, json: false, compact: false, write: false, projectRoot: '', workflowId: '', migrationSource: '', confirmMigration: false, takeover: false, sessionId: '', workflowType: '', scope: '', userGoal: '', reason: '', input: '', result: '', feedbackId: '', planId: '', hostContextChars: '', runtimeContextChars: '', privateRegistryRoot: '', noPrivateRegistry: false, pendingActionId: '', visibleChoiceHash: '', stateVersion: '', bookRoot: '' };
  for (let i = implicitCommand ? 2 : 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') args.json = true;
    else if (arg === '--compact') args.compact = true;
    else if (arg === '--write') args.write = true;
    else if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--source') args.migrationSource = argv[++i] || '';
    else if (arg === '--confirm') args.confirmMigration = true;
    else if (arg === '--takeover') args.takeover = true;
    else if (arg === '--session-id') args.sessionId = argv[++i] || '';
    else if (arg === '--workflow-type') args.workflowType = argv[++i] || '';
    else if (arg === '--scope') args.scope = argv[++i] || '';
    else if (arg === '--user-goal') args.userGoal = argv[++i] || '';
    else if (arg === '--reason') args.reason = argv[++i] || '';
    else if (arg === '--input') args.input = argv[++i] || '';
    else if (arg === '--pending-action-id') args.pendingActionId = argv[++i] || '';
    else if (arg === '--visible-choice-hash') args.visibleChoiceHash = argv[++i] || '';
    else if (arg === '--state-version') args.stateVersion = argv[++i] || '';
    else if (arg === '--book-root') args.bookRoot = argv[++i] || '';
    else if (arg === '--result') args.result = argv[++i] || '';
    else if (arg === '--feedback-id') args.feedbackId = argv[++i] || '';
    else if (arg === '--plan-id') args.planId = argv[++i] || '';
    else if (arg === '--host-context-chars') args.hostContextChars = argv[++i] || '';
    else if (arg === '--runtime-context-chars') args.runtimeContextChars = argv[++i] || '';
    else if (arg === '--private-registry-root') args.privateRegistryRoot = argv[++i] || '';
    else if (arg === '--no-private-registry') args.noPrivateRegistry = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!isPublicCommand(command)) fail('missing or invalid command');
  if (command !== 'templates' && !args.projectRoot) fail('missing --project-root');
  if ((command === 'create' || command === 'switch-intent') && !args.workflowType) fail('missing --workflow-type');
  if (command === 'activate' && !args.workflowId) fail('missing --workflow-id');
  if (['migrate-longform-successor', 'reset-incompatible-review-batches', 'continue-review-with-legacy-evidence', 'restore-incomplete-workflow', 'reset-unmanaged-review-repair', 'reconcile-runtime', 'refresh-short-title-lock', 'resume-pending-short-feedback', 'discard-short-feedback-item', 'reclassify-short-feedback-item', 'migrate-short-lean-workflow'].includes(command) && !args.workflowId) fail('missing --workflow-id');
  if (['discard-short-feedback-item', 'reclassify-short-feedback-item'].includes(command) && !args.feedbackId) fail('missing --feedback-id');
  if (command === 'reconcile-runtime' && !args.sessionId) fail('missing --session-id');
  if (command === 'resolve-action' && !args.input) fail('missing --input');
  if (command === 'apply-result' && !args.result) fail('missing --result');
  return args;
}

function templates() {
  return ACTIVE_TEMPLATES || BASE_TEMPLATES;
}

function resolvedTemplateForTask(task) {
  return resolveTemplateForTask(task, {
    templates: ACTIVE_TEMPLATES || BASE_TEMPLATES,
    registries: ACTIVE_REGISTRIES,
  });
}

function blockedTaskTemplate(registryCheck) {
  return blocked(registryCheck.status, [{
    field: 'workflow_registry',
    message: '任务绑定的工作流模板不可用，禁止回落到其他公有或私有模块。',
    workflow_type: registryCheck.workflow_type,
    owner_module: registryCheck.owner_module,
    expected_profile: ((registryCheck.registry || {}).profile) || 'public',
  }]);
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(1);
}

function workflowDir(root) {
  return path.join(root, '追踪', 'workflow');
}

function currentTaskPath(root) {
  return path.join(workflowDir(root), 'current-task.json');
}

function currentTaskMdPath(root) {
  return path.join(workflowDir(root), 'current-task.md');
}

function durableTaskSnapshotPath(taskOrWorkflowId) {
  if (taskOrWorkflowId && typeof taskOrWorkflowId === 'object' && taskOrWorkflowId.task_dir) {
    return `${String(taskOrWorkflowId.task_dir).replace(/\\\\/g, '/').replace(/\/$/, '')}/task.json`;
  }
  return `追踪/workflow/tasks/${String(taskOrWorkflowId || 'unknown-workflow')}/task.json`;
}

function taskRootDir(root) {
  return path.join(workflowDir(root), 'tasks');
}

function taskDir(root, workflowId) {
  return path.join(taskRootDir(root), workflowId || 'unknown-workflow');
}

function taskJsonPath(root, task) {
  return path.join(taskDir(root, task.workflow_id), 'task.json');
}

function historyPath(root) {
  return path.join(workflowDir(root), 'history.jsonl');
}

function archivedDir(root) {
  return path.join(workflowDir(root), 'archived');
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return '';
  }
}

function readFocusedAuthority(root) {
  const focused = readFocusedTask(root);
  if (!focused.pointer) return null;
  if (focused.authority.status !== 'ok') {
    return {
      __error: focused.authority.message || 'durable task snapshot is unavailable',
      __status: focused.authority.status,
    };
  }
  return focused.authority.task;
}

function blockedFocusedAuthority(task) {
  return blocked(task.__status || 'blocked_invalid_current_task', task.__error);
}

function writeCurrentTaskMarkdownIfFocused(root, task) {
  const focused = readFocusedTask(root);
  if (focused.authority.status === 'ok' && String(focused.authority.task.workflow_id || '') === String(task.workflow_id || '')) {
    atomicWriteText(currentTaskMdPath(root), renderTaskMarkdown(task));
  }
}

function persistTaskSnapshot(root, task, focus = false) {
  atomicWriteJson(path.join(taskDir(root, task.workflow_id), 'task.json'), task);
  const focused = readFocusedTask(root);
  if (focus || (focused.pointer && String(focused.pointer.workflow_id || '') === String(task.workflow_id || ''))) writeFocusPointer(root, task);
}

function writeJson(file, data) {
  atomicWriteJson(file, data);
}

function rel(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function appendJsonl(file, data) {
  appendJsonlRecord(file, data);
}

function ensureTaskPaths(root, task) {
  const dir = taskDir(root, task.workflow_id);
  const relDir = rel(root, dir);
  task.task_dir = task.task_dir || relDir;
  task.rpd_path = task.rpd_path || `${relDir}/rpd.md`;
  task.context_paths = task.context_paths || {
    context_jsonl: `${relDir}/context.jsonl`,
    verify_jsonl: `${relDir}/verify.jsonl`,
    journal_jsonl: `${relDir}/journal.jsonl`,
    result_packets_dir: `${relDir}/result-packets`,
    artifacts_dir: `${relDir}/artifacts`,
  };
  return task;
}

function initializeTaskDirectory(root, task, tpl) {
  ensureTaskPaths(root, task);
  const dir = taskDir(root, task.workflow_id);
  fs.mkdirSync(path.join(dir, 'result-packets'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'artifacts'), { recursive: true });

  const rpdFile = path.join(root, task.rpd_path);
  if (!fs.existsSync(rpdFile)) atomicWriteText(rpdFile, renderRpdMarkdown(task, tpl));

  const contextFile = path.join(dir, 'context.jsonl');
  if (!fs.existsSync(contextFile)) {
    const entries = [
      { kind: 'workflow_state', path: durableTaskSnapshotPath(task), reason: '任务持久快照；焦点指针不作为任务事实来源' },
      { kind: 'rpd', path: task.rpd_path, reason: '任务需求、读者承诺和验收标准' },
    ];
    atomicWriteText(contextFile, entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n');
  }

  const verifyFile = path.join(dir, 'verify.jsonl');
  if (!fs.existsSync(verifyFile)) {
    const entries = [
      { kind: 'state_machine', command: 'node scripts/workflow-state-machine.js inspect --project-root <book-root> --json', reason: '确认任务状态机可恢复' },
      { kind: 'task_directory', path: task.task_dir, reason: '确认 RPD/context/verify/journal 持久化目录存在' },
    ];
    atomicWriteText(verifyFile, entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n');
  }

  const journalFile = path.join(dir, 'journal.jsonl');
  if (!fs.existsSync(journalFile)) atomicWriteText(journalFile, '');
}

function renderRpdMarkdown(task, tpl) {
  const stages = tpl && Array.isArray(tpl.stages) ? tpl.stages.map((stageDef) => stageDef.stage_id).join(' -> ') : '';
  return [
    '# 任务需求与读者承诺文档',
    '',
    `- 任务编号：${task.workflow_id}`,
    `- 任务类型：${task.workflow_type}`,
    `- 用户目标：${task.user_goal || ''}`,
    `- 任务范围：${task.scope || '未限定'}`,
    `- 推进策略：${task.completion_policy}`,
    '',
    '## 读者承诺',
    '',
    '本任务必须服务当前作品的读者体验：情节可信、人物连续、钩子可追、情绪兑现，不用机械执行替代故事判断。',
    '',
    '## 任务边界',
    '',
    '- 不凭聊天记忆推进任务。',
    '- 不把阶段完成伪装成整个流程完成。',
    '- 不绕过机器门、故事质量门和状态交接。',
    '- 需要改变上游设定、大纲、细纲、素材卡或章节结构时，先回到计划/Brief 阶段。',
    '',
    '## 验收标准',
    '',
    '- 当前阶段的 result packet 与任务状态一致。',
    '- 任务事实只以任务目录 `task.json` 为准；`current-task.json` 只记录界面焦点。',
    '- 所有写入动作都有最后可信产物或验证证据。',
    '- 完成后给出下一步候选或明确收束。',
    '',
    '## 阶段序列',
    '',
    stages || '未加载模板阶段。',
    '',
  ].join('\n');
}

function writeTaskState(root, task, options = {}) {
  const tpl = templates()[task.workflow_type];
  ensureTaskPaths(root, task);
  bindPendingActionToNextState(task, root);
  initializeTaskDirectory(root, task, tpl);
  const persisted = mutateTask({
    projectRoot: root,
    workflowId: task.workflow_id,
    expectedStateVersion: Number(task.state_version || 0),
    replaceCurrent: Boolean(options.replaceCurrent),
    projectLockHeld: true,
    mutation: () => task,
    renderMarkdown: options.writeMarkdown === false ? null : renderTaskMarkdown,
  });
  Object.assign(task, persisted);
  return task;
}

function bindPendingActionToNextState(task, root) {
  if (!task.pending_action || typeof task.pending_action !== 'object') return;
  const normalized = decoratePendingAction({ ...task.pending_action, visible_choice_hash: '' });
  task.pending_action = {
    ...normalized,
    pending_action_id: String(normalized.id || ''),
    state_version: Number(task.state_version || 0) + 1,
    book_root: '.',
  };
}

function resolveProjectRootReference(reference, root) {
  const value = String(reference || '.').trim();
  if (!value || value === '.') return path.resolve(root);
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
}

function rebindTaskToCurrentProjectRoot(task) {
  if (!task || typeof task !== 'object') return false;
  let changed = false;
  const setPortable = (holder, key) => {
    if (holder && holder[key] !== '.') {
      holder[key] = '.';
      changed = true;
    }
  };
  setPortable(task, 'book_root');
  setPortable(((task.runtime_guard || {}).checkpoint_policy), 'project_root');
  setPortable(task.pending_action, 'book_root');
  setPortable(task.last_selection, 'book_root');
  return changed;
}

function appendTaskJournal(root, event, payload) {
  const workflowId = payload.workflow_id || '';
  if (!workflowId) return;
  const file = path.join(taskDir(root, workflowId), 'journal.jsonl');
  appendJsonl(file, {
    at: new Date().toISOString(),
    event,
    workflow_id: workflowId,
    workflow_type: payload.workflow_type || '',
    stage_id: payload.stage_id || payload.current_stage || '',
    step_id: payload.step_id || payload.current_step || '',
  });
}

function appendHistory(root, event, payload) {
  fs.mkdirSync(workflowDir(root), { recursive: true });
  const entry = {
    at: new Date().toISOString(),
    event,
    workflow_id: payload.workflow_id || '',
    workflow_type: payload.workflow_type || '',
    stage_id: payload.stage_id || payload.current_stage || '',
    step_id: payload.step_id || payload.current_step || '',
  };
  appendJsonlRecord(historyPath(root), entry);
  appendTaskJournal(root, event, payload);
}

function commandTemplates() {
  const templateList = Object.values(templates());
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'ok',
    templateCount: templateList.length,
    privateRegistryCount: ACTIVE_REGISTRIES.filter((item) => item.status === 'ok').length,
    privateRegistries: ACTIVE_REGISTRIES.map((item) => ({ source: item.source, status: item.status, error: item.error || '' })),
    templates: templateList,
  };
}

function createTask(args) {
  const root = path.resolve(args.projectRoot);
  const tpl = templates()[args.workflowType];
  if (!tpl) return blocked('blocked_unknown_workflow_type', `Unknown workflow type: ${args.workflowType}`);
  if (tpl.migration_only && tpl.legacy_alias_of) {
    return blocked('blocked_legacy_workflow_alias', `旧工作流 ${args.workflowType} 只用于恢复历史任务；新任务必须使用 ${tpl.legacy_alias_of}。`);
  }
  const existing = readFocusedAuthority(root);
  if (existing && existing.__error) return blockedFocusedAuthority(existing);
  const lifecycleMigration = args.workflowType === 'long_write' ? longformLifecycleMigrationBlock(existing) : null;
  if (lifecycleMigration) return lifecycleMigration;
  const matching = findExistingTaskFamilyHead(root, args);
  if (matching) {
    const matchingReviewPlan = validateTaskReviewPlan(root, matching.task);
    if (!matchingReviewPlan.blocked) {
      return (args.workflowType === 'long_write' && longformLifecycleMigrationBlock(matching.task)) || matching;
    }
  }
  const previousID = existing && hasActiveWorkflowStatus(existing.status) ? String(existing.workflow_id || '') : '';
  const task = buildNewTask(args, tpl, { previousWorkflowID: previousID, reason: previousID ? 'create_new_workflow' : '' });
  bindTaskFamily(root, task);
  if (previousID) {
    const preserved = pauseTaskForFocusSwitch(root, existing, task.workflow_id, 'create_new_workflow');
    appendHistory(root, 'focus_switched_from', preserved);
  }
  writeTaskState(root, task, { replaceCurrent: true });
  const baseline = captureCanonicalBaseline(root, task);
  if (baseline.declared_write_set.length > 0) {
    task.canonical_write_baseline = baseline;
    writeTaskState(root, task);
  }
  appendHistory(root, 'created', task);
  return { schemaVersion: SCHEMA_VERSION, status: 'created', previous_workflow_id: previousID, preserved_previous_task: Boolean(previousID), task };
}

function migrateLegacyWorkflows(args) {
  const root = path.resolve(args.projectRoot);
  const migrationSource = normalizeMigrationSource(args.migrationSource);
  const scan = scanWorkflowMigrations(root, { migrationSource });
  const inventory = scan.inventory;
  if (!args.write) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'migration_preview',
      migration_inventory: inventory,
      migrated_count: 0,
      safe_default: '默认只预演和提示；作者明确选择任务后才允许使用 --write 执行迁移。',
    };
  }

  const actionable = scan.records.filter((record) => {
    const item = record.inventory_item;
    return item.active
      && item.migration_adapter === 'legacy_fixed_review_batches'
      && ['auto-safe', 'confirm-required'].includes(item.classification);
  });
  if (!args.workflowId && actionable.some((record) => record.inventory_item.classification === 'auto-safe')) {
    return blocked('blocked_migration_confirmation_required', '迁移需要先在任务收件箱中明确选择“执行迁移并继续”；请带上所选 workflow_id 后再使用 --write。');
  }

  if (!args.workflowId) {
    const inventoryPath = writeMigrationInventory(root, inventory);
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'migration_no_changes',
      migration_inventory: inventory,
      migration_inventory_path: inventoryPath,
      migrated_count: 0,
      migrations: [],
    };
  }

  const selected = actionable.find((record) => record.inventory_item.workflow_id === args.workflowId || record.inventory_item.id === args.workflowId);
  if (!selected) return blocked('blocked_migration_selection_invalid', '所选迁移任务不存在、已结束，或当前不可执行。请重新查看任务收件箱。');
  if (selected.inventory_item.classification === 'confirm-required' && !args.confirmMigration) {
    return blocked('blocked_migration_confirmation_required', '该审阅任务处于高风险阶段；请在确认后使用 --confirm 执行迁移。');
  }

  const migrated = migrateLegacyFixedReview(root, selected.task, selected.inventory_item);
  if (migrated.status.startsWith('blocked_')) {
    inventory.items = inventory.items.map(candidate => candidate.id === selected.inventory_item.id ? { ...candidate, outcome: migrated.status } : candidate);
    const inventoryPath = writeMigrationInventory(root, inventory);
    return { ...migrated, migration_inventory: inventory, migration_inventory_path: inventoryPath, migrated_count: 0 };
  }
  inventory.items = inventory.items.map(candidate => candidate.id === selected.inventory_item.id ? { ...candidate, outcome: 'migrated', successor_workflow_id: migrated.successor_workflow_id } : candidate);
  const inventoryPath = writeMigrationInventory(root, inventory);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'migration_applied',
    migration_inventory: inventory,
    migration_inventory_path: inventoryPath,
    migrated_count: 1,
    migrations: [migrated],
  };
}

function migrateLegacyFixedReview(root, legacyTask, inventoryItem) {
  const liveTask = readFocusedAuthority(root);
  if (liveTask && liveTask.__error) return blockedFocusedAuthority(liveTask);
  if (!liveTask || liveTask.workflow_id !== legacyTask.workflow_id) {
    return blocked('blocked_legacy_migration_not_current', '旧固定批次审阅已不再是 current-task；必须重新预演后确认迁移。');
  }
  const tpl = templates().review_repair;
  let successor;
  try {
    successor = buildNewTask({
      projectRoot: root,
      workflowType: 'review_repair',
      scope: legacyTask.scope || '',
      userGoal: legacyTask.user_goal || ((legacyTask.lifecycle || {}).user_goal) || legacyTask.scope || 'review_repair',
      hostContextChars: '',
      runtimeContextChars: '',
    }, tpl, {
      previousWorkflowID: legacyTask.workflow_id,
      reason: 'legacy_fixed_review_batches',
      deferReviewPlanWrite: true,
      writeEvidence: false,
    });
  } catch (error) {
    if (error && error.code === 'REVIEW_PLAN_EVIDENCE_INCOMPLETE') {
      return blocked('blocked_review_plan_evidence_incomplete', `章节证据不完整或不可信：${error.evidence_status || 'unknown'}`);
    }
    if (error && error.code === 'REVIEW_BATCH_PLAN_OVERSIZED') return blockedOversizedReviewPlan(error);
    throw error;
  }

  const reviewPlan = successor.__review_plan;
  delete successor.__review_plan;
  const snapshotPath = path.join(archivedDir(root), `${legacyTask.workflow_id}.legacy-snapshot.json`);
  const snapshotRel = rel(root, snapshotPath);
  successor.migration = {
    kind: 'workflow_legacy_upgrade',
    reason: 'legacy_fixed_review_batches',
    source_workflow_id: legacyTask.workflow_id,
    source: inventoryItem.migration_source || '',
    source_paths: inventoryItem.source_paths,
    rollback_snapshot: snapshotRel,
    migrated_at: new Date().toISOString(),
  };

  fs.mkdirSync(archivedDir(root), { recursive: true });
  writeJson(snapshotPath, legacyTask);
  const reference = writeReviewPlan(root, successor, reviewPlan);
  successor.review_plan_path = reference.path;
  successor.review_plan_digest = reference.digest;
  const archived = archiveSupersededTask(root, legacyTask, successor.workflow_id, 'legacy_fixed_review_batches');
  writeTaskState(root, successor, { replaceCurrent: true });
  appendHistory(root, 'legacy_migrated', archived);
  appendHistory(root, 'created_from_legacy_migration', successor);
  return {
    status: 'migrated',
    predecessor_workflow_id: legacyTask.workflow_id,
    successor_workflow_id: successor.workflow_id,
    snapshot_path: snapshotRel,
    review_plan_path: successor.review_plan_path,
  };
}

function migrateLegacyLongformSuccessor(args) {
  const root = path.resolve(args.projectRoot);
  const source = normalizeMigrationSource(args.migrationSource);
  if (!source) return blocked('blocked_migration_source_required', '长篇旧协议迁移必须明确来源为 oh-story 或 novel-assistant-previous。');
  if (!args.confirmMigration) {
    return longformMigrationMenu(args.workflowId, '迁移会保留旧任务，并创建一个按当前协议重新验收的继任任务。');
  }

  const legacyFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const legacyTask = readJson(legacyFile);
  if (!legacyTask || legacyTask.__error || legacyTask.workflow_type !== 'long_write' || legacyTask.lifecycle_graph) {
    return blocked('blocked_longform_migration_task_invalid', '目标不是可迁移的旧 long_write 任务，或已经使用当前生命周期协议。');
  }
  const lifecycleIndexPath = path.join(root, '追踪', 'workflow', 'longform-lifecycle.json');
  const lifecycleIndex = readJson(lifecycleIndexPath);
  const migration = lifecycleIndex && lifecycleIndex.migration;
  if (!lifecycleIndex || lifecycleIndex.__error || !migration
    || String(migration.migrated_from_workflow_id || '') !== args.workflowId
    || String(migration.source || '') !== source) {
    return blocked('blocked_longform_lifecycle_index_untrusted', '生命周期索引与所选旧任务或迁移来源不一致；请重新执行迁移预演。');
  }

  const tpl = templates().long_write;
  const assets = lifecycleIndex.assets && typeof lifecycleIndex.assets === 'object' ? lifecycleIndex.assets : {};
  const ordered = tpl.stages.map(stageDef => stageDef.stage_id);
  const earliestUntrusted = ordered.find(stageId => String(assets[stageId] || 'missing') !== 'accepted') || 'book_acceptance';
  const currentStage = findStage(tpl, earliestUntrusted) || tpl.stages[0];
  const currentIndex = ordered.indexOf(currentStage.stage_id);
  const acceptedBefore = ordered.slice(0, currentIndex).filter(stageId => String(assets[stageId] || '') === 'accepted');
  const successor = buildNewTask({
    projectRoot: root,
    workflowType: 'long_write',
    scope: legacyTask.scope || '',
    userGoal: legacyTask.user_goal || ((legacyTask.lifecycle || {}).user_goal) || legacyTask.scope || '继续长篇写作',
    hostContextChars: '',
    runtimeContextChars: '',
  }, tpl, {
    previousWorkflowID: legacyTask.workflow_id,
    reason: 'legacy_longform_lifecycle_successor',
  });

  successor.current_stage = currentStage.stage_id;
  successor.current_step = currentStage.stage_id;
  successor.machine.completed_stages = acceptedBefore;
  successor.machine.remaining_stages = ordered.slice(currentIndex);
  successor.machine.last_transition = 'legacy_longform_migrated';
  successor.machine.next_stop_reason = currentStage.requires_user_confirm ? 'requires_user_confirm' : 'ready_for_current_stage';
  successor.unit_lifecycle = buildUnitLifecycleState(tpl, currentStage, successor.scope || '');
  successor.pending_action = buildPendingAction(tpl, currentStage);
  successor.stage_execution = null;
  successor.lifecycle = {
    ...(successor.lifecycle || {}),
    previous_workflow_id: legacyTask.workflow_id,
    switch_reason: 'legacy_longform_lifecycle_successor',
  };
  successor.lifecycle_graph = buildLongformLifecycleGraph(tpl, currentStage.stage_id);
  successor.lifecycle_graph.completed_nodes = acceptedBefore;
  successor.lifecycle_graph.nodes = successor.lifecycle_graph.nodes.map(node => ({
    ...node,
    status: LONG_WRITE_NODE_STATUSES.has(String(assets[node.id] || '')) ? String(assets[node.id]) : 'missing',
  }));
  for (const stageId of acceptedBefore) {
    const stageDef = findStage(tpl, stageId);
    if (((stageDef || {}).review_requirement || {}).required === true) {
      successor.lifecycle_graph.review_results[stageId] = {
        status: 'accepted',
        verification_result: 'accepted',
        source: 'supported_legacy_lifecycle_index',
      };
    }
  }
  successor.migration = {
    kind: 'workflow_legacy_upgrade',
    reason: 'legacy_longform_lifecycle_successor',
    source_workflow_id: legacyTask.workflow_id,
    source,
    lifecycle_index_path: rel(root, lifecycleIndexPath),
    historical_snapshot_path: String(migration.historical_snapshot_path || ''),
    proposed_lifecycle_node: String(migration.proposed_lifecycle_node || ''),
    restart_lifecycle_node: currentStage.stage_id,
    migrated_at: new Date().toISOString(),
  };

  bindTaskFamily(root, successor);
  const archived = archiveSupersededTask(root, legacyTask, successor.workflow_id, 'legacy_longform_lifecycle_successor');
  writeTaskState(root, successor, { replaceCurrent: true });
  appendHistory(root, 'legacy_longform_migrated', archived);
  appendHistory(root, 'created_from_legacy_longform_migration', successor);
  const currentStageLabel = String(currentStage.visible_label || currentStage.description || currentStage.stage_id);
  const visible = pendingActionVisibleResponse(successor, root, `旧长篇任务已保留；新任务从“${currentStageLabel}”重新验收。`);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'longform_successor_created',
    predecessor_workflow_id: legacyTask.workflow_id,
    successor_workflow_id: successor.workflow_id,
    current_stage: currentStage.stage_id,
    current_stage_label: currentStageLabel,
    inherited_accepted_nodes: acceptedBefore,
    preserved_history: true,
    creative_files_changed: false,
    task: successor,
    pending_action: refreshedVisibleMenu(successor, root),
    next_candidates: visible.options || [],
    visible_response: visible,
    interaction_contract: 'render_visible_response_text_verbatim',
  };
}

function longformMigrationMenu(workflowId, reason) {
  const options = [
    { number: 1, label: '保留旧任务并创建新协议继任任务（推荐）', action: 'migrate_longform_successor', description: '旧证据只读保留；从最早没有可信验收的阶段继续。' },
    { number: 2, label: '查看旧任务与迁移依据', action: 'inspect_legacy_longform', description: '只读查看，不写入任务状态。' },
    { number: 3, label: '暂停并保留旧任务', action: 'pause', description: '不迁移，也不修改创作资产。' },
    { number: 4, label: '输入其他要求', action: 'free_text', description: '补充范围、迁移偏好或新的写作目标。' },
  ];
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'longform_migration_confirmation_required',
    workflow_id: workflowId,
    reason,
    options,
    text: `${reason}\n\n${options.map(option => `${option.number}. ${option.label}\n   ${option.description}`).join('\n')}\n\n回复数字选择。`,
  };
}

function buildWorkflowRegistrySnapshot(tpl, primaryOwner) {
  const overlay = (tpl && tpl.private_overlay) || null;
  const ownerModule = String((overlay || {}).module || (primaryOwner || {}).owner_module || '');
  if (!overlay) {
    return {
      profile: 'public',
      owner_module: ownerModule,
      registry_id: 'public',
      registry_digest: '',
    };
  }
  return {
    profile: 'private',
    owner_module: ownerModule,
    // registry_id 用 module 名, 稳定且对合理内容更新不敏感.
    // digest 仅记录来源路径指纹, 不参与强校验, 避免微调阻断.
    registry_id: ownerModule || 'private',
    registry_digest: String(overlay.source || ''),
  };
}

function buildNewTask(args, tpl, extra) {
  const root = path.resolve(args.projectRoot);
  const first = tpl.stages[0];
  const primaryOwner = tpl.stages.find((item) => item.owner_module && item.owner_module !== 'story-workflow') || first;
  const remaining = tpl.stages.map((item) => item.stage_id);
  const now = new Date().toISOString();
  const workflowId = createWorkflowId(args.workflowType, now);
  const task = {
    workflow_id: workflowId,
    result_contract_version: 2,
    workflow_type: args.workflowType,
    workflow_profile: tpl.private_overlay ? 'private' : 'public',
    workflow_owner: String((tpl.private_overlay || {}).module || primaryOwner.owner_module || ''),
    workflow_registry: buildWorkflowRegistrySnapshot(tpl, primaryOwner),
    production_kernel: String(tpl.production_kernel || ''),
    scheduling_contract: tpl.scheduling_contract && typeof tpl.scheduling_contract === 'object'
      ? JSON.parse(JSON.stringify(tpl.scheduling_contract))
      : null,
    book_root: '.',
    user_goal: args.userGoal || args.scope || args.workflowType,
    scope: args.scope || '',
    completion_policy: tpl.default_completion_policy,
    current_stage: first.stage_id,
    current_step: first.stage_id,
    status: 'running',
    lifecycle: {
      status: 'active',
      started_at: now,
      updated_at: now,
      user_goal: args.userGoal || args.scope || args.workflowType,
      scope: args.scope || '',
      previous_workflow_id: extra.previousWorkflowID || '',
      switch_reason: extra.reason || '',
    },
    machine: {
      template_version: SCHEMA_VERSION,
      completed_stages: [],
      remaining_stages: remaining,
      allowed_actions: ['continue_next_stage', 'pause'],
      last_transition: 'created',
      next_stop_reason: first.requires_user_confirm ? 'requires_user_confirm' : 'ready',
    },
    unit_lifecycle: buildUnitLifecycleState(tpl, first, args.scope || ''),
    host_execution_mode: 'cooperative_interactive',
    execution_boundary: normalizeExecutionBoundary({ host_execution_mode: 'cooperative_interactive' }),
    runtime_guard: buildRuntimeGuard(args, workflowId, now),
    pending_action: buildPendingAction(tpl, first),
    canonical_write_set: canonicalWriteSetForTemplate(tpl),
  };
  if (task.workflow_type === 'long_write') task.lifecycle_graph = buildLongformLifecycleGraph(tpl, first.stage_id);
  if (task.workflow_type === 'cover') task.cover_operation = inferCoverOperation(task.user_goal, task.scope);
  ensureTaskPaths(root, task);
  if (task.workflow_type === 'review_repair') {
    task.review_target = resolveReviewTarget({ text: task.user_goal, scope: task.scope }, extra.lifecycleState || {});
    task.review_evidence_policy = reviewEvidencePolicy(task.review_target);
    if (task.review_evidence_policy.use_dynamic_batches) {
      const reviewPlan = extra.reviewPlan || buildInitialReviewPlan(root, task, { writeEvidence: extra.writeEvidence !== false });
      if (extra.deferReviewPlanWrite) {
        Object.defineProperty(task, '__review_plan', { value: reviewPlan, enumerable: false, configurable: true });
      } else {
        const reference = writeReviewPlan(root, task, reviewPlan);
        task.review_plan_path = reference.path;
        task.review_plan_digest = reference.digest;
      }
      task.review_batches = buildReviewBatchState(task.workflow_id, task.scope, task.task_dir, reviewPlan);
    }
  }
  return task;
}

function canonicalWriteSetForTemplate(tpl) {
  return Array.from(new Set((tpl.stages || [])
    .flatMap((stageDef) => Array.isArray(stageDef.write_set) ? stageDef.write_set : [])
    .filter(isCanonicalTarget))).sort();
}

function buildRuntimeGuard(args, workflowId, now) {
  const root = path.resolve(args.projectRoot);
  const scopeRange = parseNumericScope(args.scope || '');
  const unitCount = scopeRange ? scopeRange.end - scopeRange.start + 1 : 1;
  const workflowType = String(args.workflowType || 'workflow');
  const estimatedUnitWindow = ['review_repair', 'short_review'].includes(workflowType) ? Math.min(12, unitCount) : workflowType === 'long_analyze' ? Math.min(30, unitCount) : 1;
  const agentCount = ['review_repair', 'short_review'].includes(workflowType) ? 2 : ['long_analyze', 'long_write'].includes(workflowType) ? 2 : 1;
  const hostContextChars = positiveContextChars(args.hostContextChars);
  const runtimeContextChars = positiveContextChars(args.runtimeContextChars);
  const tokenEstimate = {
    input_files: Math.max(1, unitCount),
    input_chars_estimate: Math.max(4000, unitCount * 3500),
    output_chars_budget: Math.max(2000, Math.min(24000, estimatedUnitWindow * 800)),
    agent_count: agentCount,
    batch_size: estimatedUnitWindow,
    estimated_unit_window: estimatedUnitWindow,
    risk_level: ['review_repair', 'short_review', 'long_analyze', 'long_write'].includes(workflowType) ? 'medium' : 'low',
  };
  if (hostContextChars) tokenEstimate.host_context_chars = hostContextChars;
  if (runtimeContextChars) tokenEstimate.context_chars_budget = runtimeContextChars;
  return {
    token_estimate: tokenEstimate,
    adaptive_budget_policy: {
      mode: 'scope_and_batch_dynamic',
      visible_reply_budget: 'summary_only',
      batch_handoff_budget: 'proportional_to_completed_units',
      range_summary_budget: 'proportional_to_open_findings',
    },
    heartbeat: {
      updated_at: now,
      latest_trusted_artifact: durableTaskSnapshotPath(workflowId),
      workflow_id: workflowId,
    },
    stall_policy: {
      heartbeat_timeout_minutes: 60,
      on_stall: 'pause_at_checkpoint',
    },
    checkpoint_policy: {
      resume_from: 'current_stage',
      checkpoint_path: durableTaskSnapshotPath(workflowId),
      project_root: '.',
    },
    output_health_gate: {
      script: 'scripts/output-pollution-check.js',
      policy: 'block_polluted_output_and_preserve_last_trusted_artifact',
    },
    max_retry_budget: {
      same_failure: 1,
      same_tool_error: 1,
      provider_error: 1,
      on_exhausted: 'pause_at_checkpoint',
    },
    token_cost_governance: {
      cost_ledger_path: '追踪/workflow/token-cost-ledger.jsonl',
      cost_summary_path: '追踪/workflow/token-cost-summary.json',
      ledger_path: '追踪/workflow/token-cost-ledger.jsonl',
      model_routing_policy: 'cheap_extract_for_mechanical_standard_for_review_deep_for_global_arbitration',
      tool_output_filter: 'persist_full_output_and_inject_summary_only',
      retry_budget_result: 'pending',
    },
  };
}

function positiveContextChars(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 0;
}

function switchIntent(args) {
  const root = path.resolve(args.projectRoot);
  const tpl = templates()[args.workflowType];
  if (!tpl) return blocked('blocked_unknown_workflow_type', `Unknown workflow type: ${args.workflowType}`);
  const existing = readFocusedAuthority(root);
  if (existing && existing.__error) return blockedFocusedAuthority(existing);
  const lifecycleMigration = args.workflowType === 'long_write' ? longformLifecycleMigrationBlock(existing) : null;
  if (lifecycleMigration) return lifecycleMigration;
  const explicitBranch = /(^|\s)(retry|replan|branch)(\s|$)|重试|重新规划|重新计划|重新验收|回炉/.test(String(args.reason || ''));
  const matching = explicitBranch ? null : findExistingTaskFamilyHead(root, args);
  if (matching) return (args.workflowType === 'long_write' && longformLifecycleMigrationBlock(matching.task)) || matching;
  if (existing) {
    const reviewPlanValidation = validateTaskReviewPlan(root, existing);
    if (reviewPlanValidation.blocked) return reviewPlanValidation.blocked;
    if (reviewPlanValidation.legacy) return blockedLegacyReviewPlan(existing);
  }
  const previousID = existing && existing.workflow_id ? existing.workflow_id : '';
  const task = buildNewTask(args, tpl, { previousWorkflowID: previousID, reason: args.reason || 'manual_new_goal' });
  if (explicitBranch && previousID) {
    task.parent_workflow_id = previousID;
    task.lifecycle.focus_switched_from = previousID;
    task.lifecycle.branch_reason = args.reason || 'explicit_replan';
  }
  bindTaskFamily(root, task);

  if (existing && previousID && !['completed', 'closed'].includes(String(existing.status || ''))) {
    const preserved = pauseTaskForFocusSwitch(root, existing, task.workflow_id, args.reason || 'manual_new_goal');
    appendHistory(root, 'focus_switched_from', preserved);
  }

  writeTaskState(root, task, { replaceCurrent: true });
  const baseline = captureCanonicalBaseline(root, task);
  if (baseline.declared_write_set.length > 0) {
    task.canonical_write_baseline = baseline;
    writeTaskState(root, task);
  }
  appendHistory(root, 'created', task);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: explicitBranch ? 'branched' : 'switched',
    previous_workflow_id: previousID,
    preserved_previous_task: Boolean(previousID),
    task_family_id: task.task_family_id,
    branch_reason: explicitBranch ? task.lifecycle.branch_reason : '',
    task,
  };
}

function findExistingTaskFamilyHead(root, args) {
  if (!String(args.scope || '').trim() && args.workflowType !== 'review_repair') return null;
  const request = {
    workflow_id: `request-${String(args.workflowType || 'workflow')}`,
    workflow_type: args.workflowType,
    scope: args.scope || '',
    user_goal: args.userGoal || args.scope || args.workflowType,
  };
  const relationship = resolveTaskRelationship(root, request);
  if (relationship.kind !== 'same_family' || !relationship.family || !relationship.family.head_workflow_id) return null;
  const headFile = path.join(taskDir(root, relationship.family.head_workflow_id), 'task.json');
  const head = readJson(headFile);
  if (!head || head.__error || ['completed', 'closed', 'cancelled', 'canceled'].includes(String(head.status || '').toLowerCase())) return null;
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'attached_existing_family',
    task_family_id: relationship.family.task_family_id,
    relationship: relationship.reason,
    task: head,
  };
}

function bindTaskFamily(root, task) {
  const registration = ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
  task.task_family_id = registration.family.task_family_id;
  task.branch_id = task.workflow_id;
  task.branch_status = String((registration.branch || {}).status || 'active');
  return registration;
}

function activateTask(args) {
  const root = path.resolve(args.projectRoot);
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const target = readJson(targetFile);
  if (!target || target.__error) return blocked('blocked_workflow_task_not_found', `找不到可恢复任务：${args.workflowId}`);
  if (['completed', 'closed', 'cancelled', 'canceled'].includes(String(target.status || ''))) {
    return blocked('blocked_workflow_task_not_resumable', `任务已结束：${args.workflowId}`);
  }
  const current = readFocusedAuthority(root);
  if (current && current.__error) return blockedFocusedAuthority(current);
  if (current && current.workflow_id && current.workflow_id !== target.workflow_id && !['completed', 'closed'].includes(String(current.status || ''))) {
    const preserved = pauseTaskForFocusSwitch(root, current, target.workflow_id, 'activate_existing_workflow');
    appendHistory(root, 'focus_switched_from', preserved);
  }
  const now = new Date().toISOString();
  const activated = {
    ...target,
    status: String(target.status || '') === 'paused' ? 'running' : target.status,
    lifecycle: {
      ...(target.lifecycle || {}),
      status: 'active',
      resumed_at: now,
      updated_at: now,
      focus_switched_from: current && current.workflow_id !== target.workflow_id ? current.workflow_id : '',
    },
    state_version: Number(target.state_version || 0) + 1,
    updated_at: now,
  };
  const overviewBeforeActivation = workflowTaskOverview(activated, root);
  if (!overviewBeforeActivation && activated.stage_execution && activated.stage_execution.status === 'paused' && activated.stage_execution.stop_reason === 'focus_switched') {
    activated.stage_execution = { ...activated.stage_execution, status: 'running', resumed_at: now };
    delete activated.stage_execution.stopped_at;
    delete activated.stage_execution.stop_reason;
  }
  if (activated.pending_action && typeof activated.pending_action === 'object') {
    activated.pending_action = { ...activated.pending_action, state_version: activated.state_version, book_root: '.' };
  }
  // A deliberate branch activation changes the family head. Old sessions that keep
  // an earlier current-task snapshot cannot project results after this point.
  bindTaskFamily(root, activated);
  // Entering a multi-subtask task only reveals its overview. Execution starts
  // after the user explicitly opens the current subtask.
  const autoStart = overviewBeforeActivation
    ? { started: false, stageExecution: null }
    : maybeAutoStartInternalStage(root, activated);
  persistTaskSnapshot(root, activated, true);
  writeCurrentTaskMarkdownIfFocused(root, activated);
  appendTaskJournal(root, 'activated', activated);
  appendHistory(root, 'activated', activated);
  const taskOverview = overviewBeforeActivation || workflowTaskOverview(activated, root);
  const taskOverviewData = taskOverview ? omitVisibleResponse(taskOverview) : null;
  return {
    schemaVersion: SCHEMA_VERSION,
    status: autoStart.started ? 'stage_started' : 'activated',
    previous_workflow_id: current && current.workflow_id ? current.workflow_id : '',
    task: activated,
    stage_execution: autoStart.stageExecution || null,
    task_overview: taskOverviewData,
    visible_response: taskOverview ? taskOverview.visible_response : null,
  };
}

function restoreIncompleteWorkflow(args) {
  const root = path.resolve(args.projectRoot);
  if (!args.confirmMigration) {
    return blocked('blocked_workflow_integrity_restore_confirmation_required', '恢复会重开已标记完成但漏阶段的任务；请确认后使用 --confirm。');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(String(args.workflowId || ''))) {
    return blocked('blocked_workflow_task_not_found', `找不到任务：${args.workflowId}`);
  }
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const task = readJson(targetFile);
  if (!task || task.__error) return blocked('blocked_workflow_task_not_found', `找不到任务：${args.workflowId}`);
  const tpl = templates()[task.workflow_type];
  if (!tpl || !['completed', 'closed'].includes(String(task.status || '').toLowerCase())) {
    return blocked('blocked_workflow_integrity_restore_not_applicable', '只有已完成任务才能进行完整性恢复。');
  }
  const ordered = tpl.stages.map(stageDef => stageDef.stage_id);
  const completed = new Set(Array.isArray((task.machine || {}).completed_stages) ? task.machine.completed_stages.map(String) : []);
  const missing = ordered.filter(stageId => !completed.has(stageId));
  if (!missing.length) return { schemaVersion: SCHEMA_VERSION, status: 'workflow_integrity_current', workflow_id: task.workflow_id };
  const resumeStage = missing[0];
  if (resumeStage === 'execute_repair') {
    const stagedDir = path.join(root, task.task_dir, 'artifacts', 'staged_repair_candidate');
    const hasDraft = fs.existsSync(stagedDir) && fs.readdirSync(stagedDir).some(name => /\.draft\.md$/i.test(name));
    if (!hasDraft) return blocked('blocked_workflow_integrity_repair_artifact_missing', '缺少已审定的修复草稿，不能直接跳到执行修复。');
  }
  const now = new Date().toISOString();
  const resumeIndex = ordered.indexOf(resumeStage);
  task.status = 'paused';
  task.current_stage = resumeStage;
  task.current_step = resumeStage;
  task.lifecycle = { ...(task.lifecycle || {}), status: 'paused', updated_at: now, completed_at: '', integrity_recovery_at: now };
  task.machine = normalizeMachine(task, tpl);
  task.machine.completed_stages = ordered.slice(0, resumeIndex).filter(stageId => completed.has(stageId));
  task.machine.remaining_stages = ordered.slice(resumeIndex);
  task.machine.allowed_actions = ['continue_next_stage', 'pause'];
  task.machine.last_transition = 'workflow_integrity_restored';
  task.machine.next_stop_reason = 'integrity_recovery_requires_activation';
  const expected = expectedResultPacketPath(task, resumeStage);
  task.stage_execution = { status: 'paused', stage_id: resumeStage, step_id: resumeStage, expected_result_packet: expected, owner_module: (findStage(tpl, resumeStage) || {}).owner_module || '', risk_level: (findStage(tpl, resumeStage) || {}).risk_level || 'medium', resume_hint: `恢复后从 ${resumeStage} 继续。` };
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.heartbeat = { ...((task.runtime_guard || {}).heartbeat || {}), updated_at: now, latest_trusted_artifact: `${task.task_dir}/artifacts/staged_repair_candidate/`, workflow_id: task.workflow_id };
  task.runtime_guard.checkpoint_policy = { ...((task.runtime_guard || {}).checkpoint_policy || {}), resume_from: resumeStage, checkpoint_path: durableTaskSnapshotPath(task), expected_result_packet: expected, project_root: '.' };
  task.pending_action = buildPendingAction(tpl, findStage(tpl, resumeStage));
  task.integrity_recovery = { restored_at: now, reason: 'completed_task_missing_required_stage', missing_stages: missing, resume_stage: resumeStage, requires_activation: true };
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = now;
  persistTaskSnapshot(root, task);
  appendTaskJournal(root, 'workflow_integrity_restored', task);
  appendHistory(root, 'workflow_integrity_restored', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, resume_stage: resumeStage, missing_stages: missing });
  return { schemaVersion: SCHEMA_VERSION, status: 'workflow_integrity_restored', workflow_id: task.workflow_id, missing_stages: missing, resume_stage: resumeStage, activation_command: `node scripts/workflow-state-machine.js activate --project-root ${shellQuote(root)} --workflow-id ${shellQuote(task.workflow_id)} --json` };
}

function resetUnmanagedReviewRepair(args) {
  const root = path.resolve(args.projectRoot);
  if (!args.confirmMigration) {
    return blocked('blocked_review_repair_reset_confirmation_required', '检测到未受控写入风险；重建候选修复方案前请确认。');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(String(args.workflowId || ''))) {
    return blocked('blocked_workflow_task_not_found', `找不到审阅任务：${args.workflowId}`);
  }
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const task = readJson(targetFile);
  if (!task || task.__error || task.workflow_type !== 'review_repair') {
    return blocked('blocked_workflow_task_not_found', `找不到可重建的审阅修复任务：${args.workflowId}`);
  }
  const current = readFocusedAuthority(root);
  if (current && current.__error) return blockedFocusedAuthority(current);
  if (current && current.workflow_id && current.workflow_id !== task.workflow_id && hasActiveWorkflowStatus(current.status)) {
    return blocked('blocked_workflow_task_conflict', `当前另有未完成任务：${current.workflow_id}`);
  }

  const tpl = templates().review_repair;
  const resumeStage = 'repair_execution_plan';
  const resumeIndex = tpl.stages.findIndex(stageDef => stageDef.stage_id === resumeStage);
  if (resumeIndex < 0) return blocked('blocked_workflow_template_invalid', '审阅修复工作流缺少修复执行方案阶段。');

  const now = new Date().toISOString();
  const taskDirectory = taskDir(root, task.workflow_id);
  const candidateDir = path.join(taskDirectory, 'artifacts', 'staged_repair_candidate');
  const archiveName = `staged_repair_candidate.archived-${now.replace(/[:.]/g, '').replace('T', '_').replace('Z', '')}`;
  const archivedDir = path.join(taskDirectory, 'artifacts', archiveName);
  let archivedCandidateDir = String(((task.repair_integrity_recovery || {}).archived_candidate_dir) || '');
  if (fs.existsSync(candidateDir)) {
    const safeCandidate = resolveSafeProjectFile(root, candidateDir);
    const safeArchive = resolveSafeProjectFile(root, archivedDir);
    if (!safeCandidate || !safeArchive || !fs.statSync(safeCandidate).isDirectory()) {
      return blocked('blocked_review_repair_candidate_archive_failed', '候选修复稿目录不在安全项目路径内，不能重建。');
    }
    fs.renameSync(safeCandidate, safeArchive);
    archivedCandidateDir = rel(root, safeArchive);
  }
  if (!archivedCandidateDir) archivedCandidateDir = latestArchivedRepairCandidate(root, taskDirectory);

  task.current_stage = resumeStage;
  task.current_step = resumeStage;
  task.status = 'running';
  task.lifecycle = { ...(task.lifecycle || {}), status: 'active', completed_at: '', updated_at: now };
  task.machine = normalizeMachine(task, tpl);
  task.machine.completed_stages = tpl.stages.slice(0, resumeIndex)
    .map(stageDef => stageDef.stage_id)
    .filter(stageId => (task.machine.completed_stages || []).includes(stageId));
  task.machine.remaining_stages = tpl.stages.slice(resumeIndex).map(stageDef => stageDef.stage_id);
  task.machine.allowed_actions = ['continue_next_stage', 'pause'];
  task.machine.last_transition = 'unmanaged_repair_candidates_invalidated';
  task.machine.next_stop_reason = 'rebuild_controlled_repair_candidates';
  const expected = expectedResultPacketPath(task, resumeStage);
  task.stage_execution = {
    status: 'paused', stage_id: resumeStage, step_id: resumeStage,
    expected_result_packet: expected, owner_module: (findStage(tpl, resumeStage) || {}).owner_module || 'story-workflow',
    risk_level: 'medium', resume_hint: '先基于当前正文重新生成受控修复方案；旧候选稿仅保留为历史参考。',
  };
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.heartbeat = { ...((task.runtime_guard || {}).heartbeat || {}), updated_at: now, latest_trusted_artifact: archivedCandidateDir || ((task.runtime_guard.heartbeat || {}).latest_trusted_artifact || ''), workflow_id: task.workflow_id };
  task.runtime_guard.checkpoint_policy = { ...((task.runtime_guard || {}).checkpoint_policy || {}), resume_from: resumeStage, checkpoint_path: durableTaskSnapshotPath(task), expected_result_packet: expected, project_root: '.' };
  task.repair_integrity_recovery = {
    detected_at: now,
    reason: String(args.reason || 'unmanaged_canonical_write_suspected'),
    archived_candidate_dir: archivedCandidateDir,
    invalidated_stages: tpl.stages.slice(resumeIndex).map(stageDef => stageDef.stage_id),
    requires_current_text_recheck: true,
    untrusted_artifact_globs: ['scripts/apply-*.js', '追踪/审查报告/*执行报告*.md'],
    reuse_policy: '重新规划时只以当前正式正文和本轮可信证据为准；不得复用未受控脚本、其执行报告或归档候选稿作为修复来源。',
  };
  task.pending_action = decoratePendingAction({
    id: `pa-repair-replan-${task.workflow_id}`,
    question: '检测到未受控改写风险，需先重建受控修复方案',
    options: [
      { number: 1, action_id: 'continue_next_stage', label: '重新生成受控修复方案', target_stage: resumeStage, risk_level: 'medium', requires_user_confirm: false, execution_mode: 'exact_selected_option', completion_boundary: 'stage_completed' },
      { number: 2, action_id: 'pause', label: '停止并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = now;
  persistTaskSnapshot(root, task);
  writeCurrentTaskMarkdownIfFocused(root, task);
  appendTaskJournal(root, 'unmanaged_repair_candidates_invalidated', { workflow_id: task.workflow_id, archived_candidate_dir: archivedCandidateDir, reason: task.repair_integrity_recovery.reason });
  appendHistory(root, 'unmanaged_repair_candidates_invalidated', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, archived_candidate_dir: archivedCandidateDir });
  return { schemaVersion: SCHEMA_VERSION, status: 'review_repair_candidates_invalidated', workflow_id: task.workflow_id, resume_stage: resumeStage, archived_candidate_dir: archivedCandidateDir, requires_current_text_recheck: true };
}

function latestArchivedRepairCandidate(root, taskDirectory) {
  const artifactsDir = path.join(taskDirectory, 'artifacts');
  if (!fs.existsSync(artifactsDir)) return '';
  const names = fs.readdirSync(artifactsDir)
    .filter(name => /^staged_repair_candidate\.archived-[A-Za-z0-9_-]+$/.test(name))
    .sort();
  if (!names.length) return '';
  const candidate = resolveSafeProjectFile(root, path.join(artifactsDir, names.at(-1)));
  return candidate && fs.existsSync(candidate) ? rel(root, candidate) : '';
}

function shortResultPacket(root, task, stageId) {
  const file = resolveSafeProjectFile(root, `${task.task_dir}/result-packets/${stageId}.result.json`);
  return file && fs.existsSync(file) ? readJson(file) : null;
}

function shortPacketPassed(packet) {
  if (!packet || packet.__error) return false;
  if (['blocked', 'failed'].includes(String(packet.step_status || '').toLowerCase())) return false;
  if (Array.isArray(packet.blocking_findings) && packet.blocking_findings.length > 0) return false;
  return /^(pass|passed|accepted|approved|ok|completed)$/.test(String(packet.verification_result || packet.machine_gate_result || packet.quality_gate_result || '').toLowerCase());
}

function assessShortLeanMigration(root, task) {
  if (!isShortWritingWorkflow(task)) return { status: 'blocked_not_short_workflow', eligible: false };
  const machinePacket = shortResultPacket(root, task, 'section_machine_gate');
  const qualityPacket = shortResultPacket(root, task, 'quality_gate');
  const comparePacket = shortResultPacket(root, task, 'section_candidate_compare');
  const candidateCount = Number((comparePacket || {}).candidate_count || (qualityPacket || {}).candidate_count || 0)
    || (String((comparePacket || {}).comparison_result || '').includes('single_candidate') ? 1 : 1);
  const currentStage = String(task.current_stage || '');
  if (currentStage === 'section_candidate_compare') {
    if (!shortPacketPassed(machinePacket) || !shortPacketPassed(qualityPacket)) {
      return { status: 'blocked_short_quality_not_passed', eligible: false, current_stage: currentStage, candidate_count: candidateCount };
    }
    if (candidateCount > 1) return { status: 'comparison_required', eligible: false, current_stage: currentStage, candidate_count: candidateCount };
    return { status: 'eligible_single_candidate_skip', eligible: true, current_stage: currentStage, target_stage: 'section_accept_anchor', candidate_count: 1 };
  }
  if (currentStage === 'next_section_brief') {
    return { status: 'eligible_resume_next_brief', eligible: true, current_stage: currentStage, target_stage: 'next_section_brief', candidate_count: 1 };
  }
  return { status: 'eligible_identity_refresh', eligible: true, current_stage: currentStage, target_stage: currentStage, candidate_count: candidateCount };
}

function migrateShortLeanWorkflow(args) {
  const root = path.resolve(args.projectRoot);
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return blocked(authority.status, authority.message || '找不到短篇任务。');
  const task = authority.task;
  const assessment = assessShortLeanMigration(root, task);
  if (!assessment.eligible) return { schemaVersion: SCHEMA_VERSION, ...assessment, workflow_id: task.workflow_id };
  if (!args.confirmMigration) {
    return { schemaVersion: SCHEMA_VERSION, ...assessment, workflow_id: task.workflow_id, requires_confirmation: true, creative_assets_modified: false };
  }

  const previousType = task.workflow_type;
  task.workflow_type = 'short_write';
  task.workflow_profile = 'private';
  task.workflow_owner = 'private-short-extension';
  task.short_lean_migration = {
    status: 'completed',
    previous_workflow_type: previousType,
    migrated_at: new Date().toISOString(),
    reason: assessment.status,
    creative_assets_modified: false,
  };
  const tpl = templates().short_write;
  const ordered = (tpl.stages || []).map((stage) => stage.stage_id);
  const targetStage = assessment.target_stage || task.current_stage;
  task.current_stage = targetStage;
  task.current_step = targetStage;
  task.status = 'running';
  task.machine = normalizeMachine(task, tpl);
  task.machine.completed_stages = (task.machine.completed_stages || []).filter((stage) => ordered.includes(stage) && stage !== targetStage);
  const targetIndex = Math.max(0, ordered.indexOf(targetStage));
  task.machine.remaining_stages = ordered.slice(targetIndex).filter((stage) => !task.machine.completed_stages.includes(stage));
  task.machine.last_transition = 'short_lean_workflow_migrated';
  task.machine.next_stop_reason = 'ready_for_current_stage';
  task.stage_execution = task.stage_execution && task.stage_execution.status === 'running'
    ? { ...task.stage_execution, status: 'paused', stopped_at: new Date().toISOString(), stop_reason: 'short_lean_workflow_migrated' }
    : task.stage_execution;
  task.pending_action = targetStage === 'section_accept_anchor'
    ? buildShortSectionDecisionPendingAction(tpl, task)
    : buildPendingAction(tpl, findStage(tpl, targetStage));
  const autoStart = maybeAutoStartInternalStage(root, task, tpl);
  writeTaskState(root, task);
  if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });

  const projectStateFile = path.join(root, '追踪/private-short-extension/project-state.json');
  const projectState = readJson(projectStateFile);
  if (projectState && !projectState.__error) {
    projectState.workflow_type = 'short_write';
    projectState.current_stage = task.current_stage;
    projectState.updated_at = new Date().toISOString();
    atomicWriteJson(projectStateFile, projectState);
  }
  appendHistory(root, 'short_lean_workflow_migrated', { workflow_id: task.workflow_id, previous_workflow_type: previousType, current_stage: task.current_stage });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: autoStart.started ? 'short_lean_workflow_migrated_stage_started' : 'short_lean_workflow_migrated',
    workflow_id: task.workflow_id,
    previous_workflow_type: previousType,
    workflow_type: task.workflow_type,
    current_stage: task.current_stage,
    creative_assets_modified: false,
    stage_execution: autoStart.stageExecution || null,
  };
}

function resetIncompatibleReviewBatches(args) {
  const root = path.resolve(args.projectRoot);
  if (!args.confirmMigration) {
    return blocked('blocked_review_batch_reset_confirmation_required', '重新验收会重置批次进度；请在明确选择后使用 --confirm。');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(String(args.workflowId || ''))) {
    return blocked('blocked_workflow_task_not_found', `找不到可重置任务：${args.workflowId}`);
  }
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const task = readJson(targetFile);
  if (!task || task.__error || task.workflow_type !== 'review_repair' || !task.review_batches || !Array.isArray(task.review_batches.batches)) {
    return blocked('blocked_workflow_task_not_found', `找不到可重置的审阅任务：${args.workflowId}`);
  }
  const current = readFocusedAuthority(root);
  if (current && current.__error) return blockedFocusedAuthority(current);
  if (current && current.workflow_id && current.workflow_id !== task.workflow_id && hasActiveWorkflowStatus(current.status)) {
    return blocked('blocked_workflow_task_conflict', `当前另有未完成任务：${current.workflow_id}`);
  }

  const firstIncompatibleIndex = task.review_batches.batches.findIndex(batch => terminalReviewBatch(batch)
    && !storedReviewPacketIsProtocolCompatible(root, task, batch));
  if (firstIncompatibleIndex < 0) {
    return { schemaVersion: SCHEMA_VERSION, status: 'review_batches_protocol_compatible', workflow_id: task.workflow_id };
  }

  const now = new Date().toISOString();
  const firstBatch = task.review_batches.batches[firstIncompatibleIndex];
  const expectedPackets = {};
  const historicalPackets = task.review_batches.batches
    .slice(firstIncompatibleIndex)
    .map(batch => String(batch.accepted_result_packet || ''))
    .filter(Boolean);
  task.review_batches.batches = task.review_batches.batches.map((batch, index) => {
    if (index < firstIncompatibleIndex) return { ...batch, status: 'completed' };
    expectedPackets[String(batch.id)] = protocolV2ReviewBatchResultPacket(task.task_dir, batch.id);
    return { ...batch, status: 'pending', accepted_result_packet: '', unresolved_dimensions: [] };
  });
  task.review_batches.completed_count = firstIncompatibleIndex;
  task.review_batches.total_count = task.review_batches.batches.length;
  task.review_batches.next_batch_id = String(firstBatch.id);
  task.review_batches.aggregate_status = 'running';
  task.review_batch_reacceptance = {
    protocolVersion: REVIEW_EVIDENCE_PROTOCOL_VERSION,
    from_batch_id: String(firstBatch.id),
    requested_at: now,
    expected_packets: expectedPackets,
    preserve_historical_packets: true,
    historical_packets: historicalPackets,
  };

  const expectedResultPacket = expectedPackets[String(firstBatch.id)];
  task.current_stage = 'evidence_scan';
  task.current_step = 'evidence_scan';
  task.status = 'running';
  task.lifecycle = { ...(task.lifecycle || {}), status: 'active', updated_at: now, completed_at: '' };
  task.machine = normalizeMachine(task, templates()[task.workflow_type]);
  const evidenceIndex = task.machine.remaining_stages.indexOf('evidence_scan');
  task.machine.completed_stages = (task.machine.completed_stages || []).filter(stageId => stageId === 'range_lock');
  task.machine.remaining_stages = evidenceIndex >= 0
    ? task.machine.remaining_stages.slice(evidenceIndex)
    : templates()[task.workflow_type].stages.map(stageDef => stageDef.stage_id).slice(1);
  task.machine.allowed_actions = ['continue_next_stage', 'pause'];
  task.machine.last_transition = 'review_batches_protocol_reset';
  task.machine.next_stop_reason = 'legacy_review_batch_reacceptance_required';
  task.stage_execution = {
    status: 'running',
    stage_attempt_id: createStageAttemptId(task.workflow_id, 'evidence_scan'),
    stage_id: 'evidence_scan',
    step_id: 'evidence_scan',
    action_id: 'continue_next_stage',
    selected_number: 1,
    started_at: now,
    batch_id: String(firstBatch.id),
    batch_scope: String(firstBatch.range || ''),
    expected_result_packet: expectedResultPacket,
    owner_module: 'story-review',
    risk_level: 'medium',
    requires_user_confirm: false,
    completion_boundary: 'batch_completed',
  };
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.heartbeat = {
    ...((task.runtime_guard || {}).heartbeat || {}),
    updated_at: now,
    current_batch: String(firstBatch.range || ''),
    workflow_id: task.workflow_id,
  };
  task.runtime_guard.checkpoint_policy = {
    ...((task.runtime_guard || {}).checkpoint_policy || {}),
    resume_from: `evidence_scan.batch-${firstBatch.id}`,
    checkpoint_path: durableTaskSnapshotPath(task),
    expected_result_packet: expectedResultPacket,
    project_root: '.',
  };
  task.pending_action = {
    ...buildReviewBatchReacceptancePendingAction(task, firstBatch),
    status: 'resolved',
    resolved_at: now,
    selected_number: 1,
    selected_action_id: 'continue_next_stage',
  };
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = now;

  persistTaskSnapshot(root, task);
  writeCurrentTaskMarkdownIfFocused(root, task);
  appendTaskJournal(root, 'review_batches_protocol_reset', { workflow_id: task.workflow_id, from_batch_id: String(firstBatch.id) });
  appendHistory(root, 'review_batches_protocol_reset', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, from_batch_id: String(firstBatch.id) });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'review_batches_reset',
    workflow_id: task.workflow_id,
    from_batch_id: String(firstBatch.id),
    next_batch: String(firstBatch.range || ''),
    expected_result_packet: expectedResultPacket,
    ...reviewBatchContinuation(root, task, firstBatch),
  };
}

function continueReviewWithLegacyEvidence(args) {
  const root = path.resolve(args.projectRoot);
  if (!args.confirmMigration) {
    return blocked('blocked_review_legacy_evidence_confirmation_required', '保留旧证据会降低该范围结论置信度；请在明确选择后使用 --confirm。');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(String(args.workflowId || ''))) {
    return blocked('blocked_workflow_task_not_found', `找不到审阅任务：${args.workflowId}`);
  }
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const task = readJson(targetFile);
  if (!task || task.__error || task.workflow_type !== 'review_repair' || !Array.isArray(((task.review_batches || {}).batches))) {
    return blocked('blocked_workflow_task_not_found', `找不到可继续的审阅任务：${args.workflowId}`);
  }
  const historical = new Set([
    ...(((task.review_batch_reacceptance || {}).historical_packets) || []),
    ...task.review_batches.batches.map(batch => String(batch.accepted_result_packet || '')).filter(Boolean),
  ]);
  const restored = [];
  for (const batch of task.review_batches.batches) {
    const candidates = [...historical].filter(item => String(item).includes(`batch-${batch.id}.`));
    const packetPath = candidates.find(item => {
      const file = resolveSafeProjectFile(root, item);
      const packet = file ? readJson(file) : null;
      return Boolean(packet && !packet.__error && ['completed', 'done'].includes(String(packet.step_status || '').toLowerCase()));
    });
    if (!packetPath) break;
    batch.status = 'completed_with_warning';
    batch.accepted_result_packet = packetPath;
    batch.unresolved_dimensions = Array.from(new Set([...(batch.unresolved_dimensions || []), 'legacy_protocol_coverage_unverified']));
    restored.push(batch);
  }
  if (!restored.length) {
    return blocked('blocked_review_legacy_evidence_missing', '未找到可保留的旧批次可信回执；请选择重新验收。');
  }
  const nextBatch = task.review_batches.batches[restored.length] || null;
  const now = new Date().toISOString();
  task.review_batches.completed_count = restored.length;
  task.review_batches.total_count = task.review_batches.batches.length;
  task.review_batches.next_batch_id = nextBatch ? String(nextBatch.id) : '';
  task.review_batches.aggregate_status = nextBatch ? 'running' : 'completed_with_warning';
  task.review_quality_debt = {
    status: 'legacy_evidence_accepted_with_warning',
    ranges: restored.map(batch => String(batch.range || '')),
    historical_packets: restored.map(batch => String(batch.accepted_result_packet || '')),
    reason: '旧批次缺少当前协议要求的来源摘要或全范围覆盖证明',
    require_final_recheck: true,
    report_disclosure_required: true,
    recorded_at: now,
  };
  task.status = 'running';
  task.lifecycle = { ...(task.lifecycle || {}), status: 'active', updated_at: now, completed_at: '' };
  task.machine = normalizeMachine(task, templates()[task.workflow_type]);
  task.machine.next_stop_reason = nextBatch ? 'stage_running_waiting_result_packet' : 'legacy_evidence_requires_final_recheck';
  task.pending_action = null;
  if (nextBatch) {
    const expected = protocolV2ReviewBatchResultPacket(task.task_dir, nextBatch.id);
    task.review_batch_reacceptance = {
      ...(task.review_batch_reacceptance || {}),
      protocolVersion: REVIEW_EVIDENCE_PROTOCOL_VERSION,
      expected_packets: { ...((task.review_batch_reacceptance || {}).expected_packets || {}), [String(nextBatch.id)]: expected },
      legacy_evidence_retained_at: now,
    };
    task.current_stage = 'evidence_scan';
    task.current_step = 'evidence_scan';
    task.stage_execution = {
      status: 'running', stage_id: 'evidence_scan', step_id: 'evidence_scan', action_id: 'continue_next_stage',
      selected_number: 2, started_at: now, batch_id: String(nextBatch.id), batch_scope: String(nextBatch.range || ''),
      expected_result_packet: expected, owner_module: 'story-review', risk_level: 'medium', requires_user_confirm: false,
      completion_boundary: 'batch_completed',
    };
    task.runtime_guard = task.runtime_guard || {};
    task.runtime_guard.heartbeat = { ...((task.runtime_guard || {}).heartbeat || {}), updated_at: now, current_batch: String(nextBatch.range || ''), workflow_id: task.workflow_id };
    task.runtime_guard.checkpoint_policy = { ...((task.runtime_guard || {}).checkpoint_policy || {}), resume_from: `evidence_scan.batch-${nextBatch.id}`, checkpoint_path: durableTaskSnapshotPath(task), expected_result_packet: expected, project_root: '.' };
  }
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = now;
  persistTaskSnapshot(root, task);
  writeCurrentTaskMarkdownIfFocused(root, task);
  appendTaskJournal(root, 'review_legacy_evidence_retained', { workflow_id: task.workflow_id, ranges: task.review_quality_debt.ranges });
  appendHistory(root, 'review_legacy_evidence_retained', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, ranges: task.review_quality_debt.ranges });
  return nextBatch ? {
    schemaVersion: SCHEMA_VERSION, status: 'review_legacy_evidence_retained', workflow_id: task.workflow_id,
    retained_ranges: task.review_quality_debt.ranges, next_batch: String(nextBatch.range || ''),
    ...reviewBatchContinuation(root, task, nextBatch),
  } : {
    schemaVersion: SCHEMA_VERSION, status: 'review_legacy_evidence_retained_requires_final_recheck', workflow_id: task.workflow_id,
    retained_ranges: task.review_quality_debt.ranges, must_continue: false,
  };
}

function hasActiveWorkflowStatus(status) {
  return !['completed', 'completed_verified', 'done', 'closed', 'cancelled', 'canceled'].includes(String(status || '').toLowerCase());
}

function storedReviewPacketIsProtocolCompatible(root, task, batch) {
  const packetPath = String(batch.accepted_result_packet || reviewBatchResultPacket(task.task_dir, batch.id));
  const packetFile = resolveSafeProjectFile(root, packetPath);
  const packet = packetFile ? readJson(packetFile) : null;
  const range = parseNumericScope(batch.range);
  const coverage = packet && packet.fullRangeCoverage;
  const expectedCount = range ? range.end - range.start + 1 : 0;
  return Boolean(packet && !packet.__error
    && packet.protocolVersion === REVIEW_EVIDENCE_PROTOCOL_VERSION
    && /^[0-9a-f]{64}$/.test(String(packet.sourceDigest || ''))
    && coverage && range
    && Number(coverage.start) === range.start
    && Number(coverage.end) === range.end
    && Number(coverage.coveredChapters) === expectedCount
    && coverage.complete === true);
}

function pauseTaskForFocusSwitch(root, task, nextWorkflowId, reason) {
  const now = new Date().toISOString();
  const preserved = {
    ...task,
    status: 'paused',
    lifecycle: {
      ...(task.lifecycle || {}),
      status: 'paused',
      paused_at: now,
      updated_at: now,
      focus_switched_to: nextWorkflowId,
      focus_switch_reason: reason,
    },
    state_version: Number(task.state_version || 0) + 1,
    updated_at: now,
  };
  if (preserved.stage_execution && preserved.stage_execution.status === 'running') {
    preserved.stage_execution = {
      ...preserved.stage_execution,
      status: 'paused',
      stopped_at: now,
      stop_reason: 'focus_switched',
      resume_hint: '重新激活本任务后从当前阶段或已有 result packet 继续。',
    };
  }
  if (preserved.pending_action && typeof preserved.pending_action === 'object') {
    preserved.pending_action = { ...preserved.pending_action, state_version: preserved.state_version, book_root: '.' };
  }
  atomicWriteJson(path.join(taskDir(root, task.workflow_id), 'task.json'), preserved);
  if (preserved.task_family_id) ensureTaskFamily(root, preserved, { write: true, projectLockHeld: true });
  appendTaskJournal(root, 'focus_paused', preserved);
  return preserved;
}

function archiveSupersededTask(root, task, supersededBy, reason) {
  const now = new Date().toISOString();
  const archived = {
    ...task,
    status: 'paused',
    lifecycle: {
      ...(task.lifecycle || {}),
      status: 'superseded',
      paused_at: now,
      updated_at: now,
      superseded_by: supersededBy,
      superseded_reason: reason,
    },
  };
  fs.mkdirSync(archivedDir(root), { recursive: true });
  writeJson(path.join(archivedDir(root), `${task.workflow_id || 'unknown-workflow'}.json`), archived);
  writeTaskState(root, archived, { writeMarkdown: false });
  return archived;
}

function inspectTask(args) {
  const root = path.resolve(args.projectRoot);
  const focused = readFocusedTask(root);
  if (!focused.pointer) return { schemaVersion: SCHEMA_VERSION, status: 'no_active_task' };
  if (focused.authority.status !== 'ok') return blocked(focused.authority.status, focused.authority.message || 'durable task snapshot is unavailable');
  const task = focused.authority.task;
  const lifecycleMigration = longformLifecycleMigrationBlock(task);
  if (lifecycleMigration) return lifecycleMigration;
  const lifecycleProgress = longformLifecycleProgressBlock(task);
  if (lifecycleProgress) return lifecycleProgress;
  const reviewPlanValidation = validateTaskReviewPlan(root, task);
  if (reviewPlanValidation.blocked) return reviewPlanValidation.blocked;
  const invariantFindings = validateTaskState(task, root);
  if (invariantFindings.length > 0) return blocked('blocked_state_invariant', invariantFindings);
  const taskOverview = workflowTaskOverview(task, root);
  const taskOverviewData = taskOverview ? omitVisibleResponse(taskOverview) : null;
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'ok',
    focus_pointer_status: focused.pointer_status || 'current',
    focus_pointer_findings: focused.pointer_findings || [],
    task: normalizeTask(task),
    task_overview: taskOverviewData,
    visible_response: taskOverview ? taskOverview.visible_response : null,
  };
}

function taskOverview(args) {
  const root = path.resolve(args.projectRoot);
  const task = readFocusedAuthority(root);
  if (!task) return { schemaVersion: SCHEMA_VERSION, status: 'no_active_task' };
  if (task.__error) return blockedFocusedAuthority(task);
  const overview = workflowTaskOverview(task, root);
  if (!overview) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'task_overview_not_required',
      workflow_id: String(task.workflow_id || ''),
      execution_command: 'node scripts/workflow-state-machine.js next-candidates --project-root . --json',
    };
  }
  const overviewData = omitVisibleResponse(overview);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'workflow_task_overview',
    workflow_id: String(task.workflow_id || ''),
    task_overview: overviewData,
    visible_response: overview.visible_response,
  };
}

function omitVisibleResponse(value) {
  if (!value || typeof value !== 'object') return value;
  const { visible_response: _visibleResponse, ...rest } = value;
  return rest;
}

function reconcileRuntime(args) {
  const root = path.resolve(args.projectRoot);
  if (!/^[A-Za-z0-9._-]+$/.test(String(args.workflowId || ''))) {
    return blocked('blocked_workflow_task_not_found', `找不到任务：${args.workflowId}`);
  }
  const targetFile = path.join(taskDir(root, args.workflowId), 'task.json');
  const task = readJson(targetFile);
  const current = readFocusedAuthority(root);
  if (current && current.__error) return blockedFocusedAuthority(current);
  if (!task || task.__error || !current || current.workflow_id !== task.workflow_id) {
    return blocked('blocked_workflow_task_not_active', '只能校正当前正在使用的任务；请先激活目标任务。');
  }
  const tpl = templates()[task.workflow_type];
  const projectRootRebound = rebindTaskToCurrentProjectRoot(task);
  const shortProjectResume = reconcileShortProjectProgress(root, task, tpl);
  if (shortProjectResume.blocked) {
    return blocked(shortProjectResume.status, shortProjectResume.findings || shortProjectResume.reason || '短篇规划状态不一致。');
  }
  if (isShortWritingWorkflow(task) && ['section_plan_lock', 'short_structure_impact_audit', 'hook_retention_gate', 'hook_value_gate', 'full_story_assembly', 'full_story_review', 'short_deslop', 'deslop', 'final_check'].includes(String(task.current_stage || ''))) {
    synchronizeShortWholeStoryScope(task, task.current_stage);
  }
  const stageDef = findStage(tpl, task.current_stage);
  if (!tpl || !stageDef || ['completed', 'closed', 'cancelled'].includes(String(task.status || '').toLowerCase())) {
    return blocked('blocked_workflow_runtime_not_reconcilable', '当前任务没有可恢复的运行阶段。');
  }
  const activeShortStageRefresh = refreshActiveShortStageGuidance(root, task);

  const now = new Date();
  const lease = (((task.runtime_guard || {}).session_lease) || {});
  const requestedSession = String(args.sessionId || '').trim();
  let familySession = null;
  if (task.task_family_id) {
    try {
      familySession = claimFamilyWriter(root, task.task_family_id, {
        session_id: requestedSession,
        host: requestedSession.split(':')[0] || 'unknown',
      }, {
        write: true,
        projectLockHeld: true,
        takeover: args.takeover === true,
        confirmed: args.confirmMigration === true,
      });
    } catch (error) {
      if (error.code !== 'TASK_FAMILY_NOT_FOUND') throw error;
    }
  }
  if (familySession && familySession.takeover_required) {
    return workflowSessionTakeoverMenu(task, requestedSession, familySession, familySession.status === 'awaiting_claim');
  }
  const leaseLive = WORKFLOW_RECOVERY.isLiveWorkflowSessionLease(lease, now);
  const otherHolder = !familySession && leaseLive && String(lease.holder_id || '') !== requestedSession;
  if (otherHolder && !(args.takeover && args.confirmMigration)) {
    return workflowSessionTakeoverMenu(task, requestedSession, { writer_lease: lease }, false);
  }

  const nowText = now.toISOString();
  const ordered = tpl.stages.map((item) => item.stage_id);
  const currentIndex = ordered.indexOf(task.current_stage);
  const priorCompleted = new Set(Array.isArray((task.machine || {}).completed_stages) ? task.machine.completed_stages.map(String) : []);
  const completedStages = ordered.slice(0, currentIndex).filter((stageId) => priorCompleted.has(stageId));
  const remainingStages = ordered.slice(currentIndex).filter((stageId) => !completedStages.includes(stageId));
  const contract = tpl.unit_lifecycle_contract || unitLifecycle('workflow_batch', {});
  const completedRoles = Array.from(new Set(completedStages
    .map((stageId) => currentUnitRole(contract, stageId))
    .filter(Boolean)));

  task.machine = normalizeMachine(task, tpl);
  task.machine.completed_stages = completedStages;
  task.machine.remaining_stages = remainingStages;
  task.machine.allowed_actions = ['continue_next_stage', 'pause'];
  task.machine.last_transition = 'runtime_reconciled';
  task.machine.next_stop_reason = 'ready_for_current_stage';
  task.status = ['paused', 'paused_after_batch'].includes(String(task.status || '').toLowerCase()) ? 'paused' : 'running';
  task.lifecycle = { ...(task.lifecycle || {}), status: task.status === 'paused' ? 'paused' : 'active', updated_at: nowText, completed_at: '' };
  task.unit_lifecycle = {
    ...(task.unit_lifecycle || {}),
    ...buildUnitLifecycleState(tpl, stageDef, task.scope || ''),
    status: 'running',
    current_scope: task.scope || '',
    current_stage: stageDef.stage_id,
    current_role: currentUnitRole(contract, stageDef.stage_id),
    completed_roles: completedRoles,
    last_trusted_artifact: WORKFLOW_RECOVERY.trustedRuntimeCheckpoint(task, root),
    updated_at: nowText,
  };
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.session_lease = {
    holder_id: requestedSession,
    workflow_id: task.workflow_id,
    acquired_at: familySession
      ? String(((familySession.writer_lease || {}).acquired_at) || nowText)
      : (otherHolder ? nowText : (lease.acquired_at || nowText)),
    heartbeat_at: nowText,
    expires_at: familySession
      ? String(((familySession.writer_lease || {}).expires_at) || new Date(now.getTime() + WORKFLOW_SESSION_LEASE_MS).toISOString())
      : new Date(now.getTime() + WORKFLOW_SESSION_LEASE_MS).toISOString(),
    host: familySession
      ? String(((familySession.writer_lease || {}).host) || requestedSession.split(':')[0] || 'unknown')
      : requestedSession.split(':')[0] || 'unknown',
    task_family_id: String(task.task_family_id || ''),
    session_role: familySession ? familySession.role : 'writer',
  };
  task.runtime_guard.heartbeat = {
    ...((task.runtime_guard || {}).heartbeat || {}),
    updated_at: nowText,
    latest_trusted_artifact: shortProjectResume.applied
      ? shortProjectResume.latest_trusted_artifact
      : WORKFLOW_RECOVERY.trustedRuntimeCheckpoint(task, root),
    workflow_id: task.workflow_id,
  };
  task.runtime_guard.checkpoint_policy = {
    ...((task.runtime_guard || {}).checkpoint_policy || {}),
    resume_from: stageDef.stage_id,
    checkpoint_path: durableTaskSnapshotPath(task),
    project_root: '.',
  };
  if (task.stage_execution && task.stage_execution.status === 'completed') {
    task.stage_execution = { ...task.stage_execution, status: 'paused', stopped_at: nowText, stop_reason: 'runtime_reconciled' };
  }
  const shortDraftStop = isShortWritingWorkflow(task)
    && ['draft_first_section', 'draft_section', 'draft_next_section'].includes(String(task.current_stage || ''))
    && (!task.stage_execution || String(task.stage_execution.status || '') !== 'running');
  if (shortProjectResume.applied || shortDraftStop) {
    task.stage_execution = null;
    task.pending_action = shortDraftStop
      ? buildShortDraftPendingAction(stageDef, task)
      : buildPendingAction(tpl, stageDef);
    bindPendingActionToNextState(task, root);
  }
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = nowText;
  persistTaskSnapshot(root, task);
  writeCurrentTaskMarkdownIfFocused(root, task);
  appendTaskJournal(root, 'runtime_reconciled', { workflow_id: task.workflow_id, current_stage: task.current_stage, session_id: requestedSession });
  appendHistory(root, 'runtime_reconciled', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, current_stage: task.current_stage, session_id: requestedSession });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'runtime_reconciled',
    workflow_id: task.workflow_id,
    current_stage: task.current_stage,
    project_progress_reconciled: shortProjectResume.applied,
    project_root_rebound: projectRootRebound,
    project_progress_resume: shortProjectResume.applied ? shortProjectResume : null,
    active_short_stage_refresh: activeShortStageRefresh,
    session_takeover: familySession
      ? ['taken_over', 'reclaimed_stale'].includes(familySession.status)
      : Boolean(otherHolder),
    session_role: familySession ? familySession.role : 'writer',
    session_claim_status: familySession ? familySession.status : 'legacy_lease',
    session_lease: task.runtime_guard.session_lease,
  };
}

function workflowSessionTakeoverMenu(task, requestedSession, familySession, stale) {
  const lease = (familySession || {}).writer_lease || {};
  const command = `node scripts/workflow-state-machine.js reconcile-runtime --project-root . --workflow-id ${shellQuote(task.workflow_id)} --session-id ${shellQuote(requestedSession)} --takeover --confirm --json`;
  const options = [
    {
      number: 1,
      label: stale ? '接管已失效会话并继续（推荐）' : '确认接管当前任务',
      action: 'confirm_session_takeover',
      description: stale ? '旧心跳已失效；保留原断点并把写权限交给当前会话。' : '另一会话可能仍在运行；确认后当前会话取得写权限。',
      execution_command: command,
    },
    { number: 2, label: '只读查看当前进度', action: 'inspect_current_state', description: '不取得写权限，不修改任务或创作资产。' },
    { number: 3, label: '暂不接管', action: 'pause', description: '保留原写会话和当前断点。' },
    { number: 4, label: '输入其他要求', action: 'free_text', description: '说明要切换的会话、任务或新目标。' },
  ];
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'workflow_session_takeover_required',
    workflow_id: String(task.workflow_id || ''),
    holder_id: String(lease.holder_session_id || lease.holder_id || ''),
    expires_at: String(lease.expires_at || ''),
    stale_session: Boolean(stale),
    options,
    text: `${stale ? '检测到旧写会话心跳已失效。' : '检测到另一写会话可能仍在运行。'}\n\n${options.map(option => `${option.number}. ${option.label}\n   ${option.description}`).join('\n')}\n\n回复数字选择。`,
  };
}

function refreshShortTitleLock(args) {
  const root = path.resolve(args.projectRoot);
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return blocked(authority.status, authority.message || '当前任务缺少可信快照。');
  const task = authority.task;
  if (!isShortWritingWorkflow(task)) return blocked('blocked_short_title_lock_wrong_workflow', '当前任务不是短篇写作任务。');
  const stageId = String(task.current_stage || '');
  if (!['first_section_brief', 'section_brief', 'next_section_brief'].includes(stageId)) {
    return blocked('blocked_short_title_lock_wrong_stage', `当前阶段不是小节写作提要：${stageId || 'unknown'}`);
  }
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return blocked('blocked_short_title_lock_stage_not_running', '当前写作提要阶段尚未启动或已经结束。');
  }
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const sectionIndex = inferShortSectionIndex({ projectState, stageId, scope: String(task.scope || '') }) || 1;
  const lock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  if (String(lock.workflow_id || '') !== String(task.workflow_id || '')
      || String(lock.project_id || '') !== String(projectState.project_id || '')
      || Number(lock.plan_revision || 0) !== Number(projectState.plan_revision || 0)) {
    return blocked('blocked_short_section_title_lock_stale', '标题清单不属于当前作品规划版本，请重新展示并确认。');
  }
  const titleEntry = (Array.isArray(lock.sections) ? lock.sections : [])
    .find((item) => Number((item || {}).section_index) === sectionIndex);
  if (!titleEntry || titleEntry.confirmed !== true) {
    return blocked('blocked_short_section_title_unconfirmed', `第${sectionIndex}节标题尚未确认。`);
  }

  delete execution.title_confirmation_required;
  delete execution.section_index;
  delete execution.stage_context_packet;
  delete execution.execution_command;
  delete execution.quality_command;
  delete execution.resume_hint;
  delete execution.context_packet_warning;
  attachShortStageExecutionGuidance(root, task, stageId);
  task.scope = `第${sectionIndex}节`;
  task.state_version = Number(task.state_version || 0) + 1;
  task.updated_at = new Date().toISOString();
  persistTaskSnapshot(root, task);
  writeCurrentTaskMarkdownIfFocused(root, task);
  appendTaskJournal(root, 'short_section_titles_bound', {
    workflow_id: task.workflow_id || '',
    section_index: sectionIndex,
    section_title: String(titleEntry.title || ''),
  });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'short_section_titles_bound',
    workflow_id: task.workflow_id || '',
    current_stage: stageId,
    section_index: sectionIndex,
    section_title: String(titleEntry.title || '') || `第${sectionIndex}节`,
    context_packet: String((((execution.stage_context_packet || {}).packet_md) || '')),
    brief_path: `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`,
    finalize_command: String(execution.execution_command || ''),
    instruction: `只读取 context_packet，生成第${sectionIndex}节写作提要。只保留承接、目标与阻力、因果动作、人物/视角锁、禁写项、节尾钩子，同一事实只写一次；完成后运行 finalize_command。不要检查状态机、读取源码或调用 inspect。`,
  };
}

function resumePendingShortFeedback(args) {
  const root = path.resolve(args.projectRoot);
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return blocked(authority.status, authority.message || '当前任务缺少可信快照。');
  const task = authority.task;
  if (!isShortWritingWorkflow(task)) return blocked('blocked_short_feedback_wrong_workflow', '当前任务不是短篇写作任务。');
  const pending = task.pending_feedback || {};
  if (!String(pending.text || '').trim()) return blocked('blocked_short_feedback_missing', '当前没有待处理的短篇反馈。');
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') return blockedTaskTemplate(registryCheck);
  let impact = task.short_feedback_impact || {};
  let impactMatchesPending = String(impact.feedback_id || '') === String(pending.feedback_id || '');
  if (!impactMatchesPending) {
    task.short_feedback_impact = recoverShortFeedbackImpact(root, task, pending);
    impact = task.short_feedback_impact || {};
    impactMatchesPending = String(impact.feedback_id || '') === String(pending.feedback_id || '');
  }
  if (!impactMatchesPending) task.short_feedback_impact = null;
  const targetStage = impactMatchesPending && String(impact.status || '') === 'ok'
    ? String(impact.impact_level || '') === 'expression_only' ? 'section_repair_loop' : 'feedback_apply_patch'
    : 'feedback_impact_sync';
  const feedbackSectionIndex = pendingFeedbackSectionIndex(pending);
  if (feedbackSectionIndex) task.scope = `第${feedbackSectionIndex}节`;
  const stageDef = findStage(registryCheck.template, targetStage);
  if (!stageDef) return blocked('blocked_short_feedback_stage_missing', `短篇工作流缺少反馈恢复阶段：${targetStage}`);
  const now = new Date().toISOString();
  reopenShortTaskForFeedback(task, now);
  if (task.stage_execution && task.stage_execution.status === 'running') {
    task.stage_execution = { ...task.stage_execution, status: 'paused', stopped_at: now, stop_reason: 'pending_feedback_resume' };
  }
  task.pending_action = null;
  const started = maybeStartStageExecution(root, task, {
    action_id: 'resume_pending_short_feedback',
    selected_number: 0,
    target_stage: targetStage,
    risk_level: stageDef.risk_level || 'medium',
    execution_contract: { completion_boundary: 'stage_completed' },
  }, now, null);
  writeTaskState(root, task);
  if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
  appendHistory(root, 'pending_short_feedback_resumed', {
    workflow_id: task.workflow_id || '',
    feedback_id: String(pending.feedback_id || ''),
    target_stage: targetStage,
  });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'pending_short_feedback_resumed',
    workflow_id: task.workflow_id || '',
    feedback_id: String(pending.feedback_id || ''),
    target_stage: targetStage,
    visible_action: targetStage === 'section_repair_loop' ? '修订当前小节并重新验收' : targetStage === 'feedback_apply_patch' ? '回写受影响的规划资产并重新验收' : '分析反馈影响范围',
    stage_execution: started.stageExecution,
  };
}

function discardShortFeedbackAndReconcile(args) {
  const root = path.resolve(args.projectRoot);
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return blocked(authority.status, authority.message || '当前任务缺少可信快照。');
  const task = authority.task;
  if (!isShortWritingWorkflow(task)) return blocked('blocked_short_feedback_wrong_workflow', '当前任务不是短篇写作任务。');
  if (!args.confirmMigration) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'confirmation_required',
      workflow_id: String(task.workflow_id || ''),
      feedback_id: String(args.feedbackId || ''),
      message: '该操作只丢弃一条误入反馈并保留审计记录；不修改正文、设定或大纲。',
    };
  }

  const now = new Date().toISOString();
  const discarded = discardShortFeedbackItem(root, task, args.feedbackId, {
    discardedAt: now,
    reason: 'host_continuation_misclassified_as_feedback',
  });
  if (discarded.status !== 'feedback_item_discarded') {
    return blocked('blocked_short_feedback_item_not_found', `待处理反馈中找不到 ${String(args.feedbackId || '')}。`);
  }

  invalidateShortFeedbackAnalysis(task, now);
  reopenShortTaskForFeedback(task, now);
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') return blockedTaskTemplate(registryCheck);
  const packet = findMatchingShortFeedbackImpactPacket(root, task);
  let recovery = 'reanalysis_started';
  if (packet) {
    task.short_feedback_impact = shortFeedbackImpactFromPacket(packet.data, packet.relative_path);
    task.current_stage = 'feedback_apply_patch';
    task.current_step = 'feedback_apply_patch';
    task.stage_execution = {
      status: 'completed',
      stage_id: 'feedback_impact_sync',
      step_id: 'feedback_impact_sync',
      completed_at: String(packet.data.completed_at || packet.data.updated_at || now),
      result_packet: packet.relative_path,
      expected_result_packet: '',
    };
    task.machine = task.machine || {};
    task.machine.completed_stages = [...new Set([
      ...(Array.isArray(task.machine.completed_stages) ? task.machine.completed_stages : []),
      'feedback_impact_sync',
    ])];
    task.machine.remaining_stages = [
      'feedback_apply_patch',
      ...(Array.isArray(task.machine.remaining_stages) ? task.machine.remaining_stages : [])
        .filter(stageId => !['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || ''))),
    ];
    task.machine.last_result_packet = packet.relative_path;
    task.machine.last_transition = 'short_feedback_item_discarded_trusted_impact_restored';
    task.runtime_guard = task.runtime_guard || {};
    task.runtime_guard.heartbeat = {
      ...(task.runtime_guard.heartbeat || {}),
      updated_at: now,
      latest_trusted_artifact: packet.relative_path,
      current_batch: 'feedback_apply_patch',
      workflow_id: String(task.workflow_id || ''),
    };
    task.runtime_guard.checkpoint_policy = {
      ...((task.runtime_guard || {}).checkpoint_policy || {}),
      resume_from: 'feedback_apply_patch',
      expected_result_packet: '',
    };
    task.pending_action = buildPendingAction(registryCheck.template, findStage(registryCheck.template, 'feedback_apply_patch'));
    recovery = 'trusted_impact_restored';
  } else {
    const stageDef = findStage(registryCheck.template, 'feedback_impact_sync');
    task.pending_action = null;
    maybeStartStageExecution(root, task, {
      action_id: 'reanalyze_feedback_after_discard',
      selected_number: 0,
      target_stage: 'feedback_impact_sync',
      risk_level: (stageDef || {}).risk_level || 'medium',
      execution_contract: { completion_boundary: 'stage_completed' },
    }, now, null);
  }

  writeTaskState(root, task);
  if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
  appendHistory(root, 'short_feedback_item_discarded_and_reconciled', {
    workflow_id: String(task.workflow_id || ''),
    discarded_feedback_id: String(args.feedbackId || ''),
    active_feedback_id: String(((task.pending_feedback || {}).feedback_id) || ''),
    recovery,
  });
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'short_feedback_state_reconciled',
    workflow_id: String(task.workflow_id || ''),
    discarded_feedback_id: String(args.feedbackId || ''),
    active_feedback_id: String(((task.pending_feedback || {}).feedback_id) || ''),
    recovery,
    current_stage: String(task.current_stage || ''),
    pending_action: task.pending_action || null,
    state_findings: validateTaskState(task, root),
  };
}

function reclassifyShortFeedbackAndReconcile(args) {
  const root = path.resolve(args.projectRoot);
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return blocked(authority.status, authority.message || '当前任务缺少可信快照。');
  const task = authority.task;
  if (!isShortWritingWorkflow(task)) return blocked('blocked_short_feedback_wrong_workflow', '当前任务不是短篇写作任务。');
  if (!args.confirmMigration) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'confirmation_required',
      workflow_id: String(task.workflow_id || ''),
      feedback_id: String(args.feedbackId || ''),
      message: '该操作只修正反馈审计分类，不修改正文、设定、大纲或已确认方案。',
    };
  }
  const acceptedPlan = task.accepted_plan || {};
  const acceptedPlanId = String(acceptedPlan.plan_id || acceptedPlan.id || '');
  const planId = String(args.planId || acceptedPlanId || '');
  if (!planId) return blocked('blocked_short_accepted_plan_missing', '缺少可绑定的已确认方案，不能把反馈重分类为方案执行指令。');
  if (acceptedPlanId && planId !== acceptedPlanId) {
    return blocked('blocked_short_accepted_plan_mismatch', '指定方案与当前已确认方案不一致，不能改写反馈审计归属。');
  }
  const correction = recordShortFeedbackReclassification(root, task, args.feedbackId, {
    preservedByPlanId: planId,
    classification: 'accepted_plan_execution_command',
  });
  if (correction.status === 'feedback_item_not_found') {
    return blocked('blocked_short_feedback_item_not_found', `反馈审计中找不到 ${String(args.feedbackId || '')}。`);
  }
  let contextRefresh = { applied: false, reason: 'stage_not_running' };
  if (String(task.current_stage || '') === 'feedback_apply_patch'
      && String(((task.stage_execution || {}).status) || '') === 'running') {
    contextRefresh = refreshActiveShortStageGuidance(root, task);
    task.state_version = Number(task.state_version || 0) + 1;
    task.updated_at = new Date().toISOString();
    persistTaskSnapshot(root, task);
    writeCurrentTaskMarkdownIfFocused(root, task);
  }
  appendHistory(root, 'short_feedback_reclassified', {
    workflow_id: String(task.workflow_id || ''),
    feedback_id: String(args.feedbackId || ''),
    plan_id: planId,
    status: correction.status,
    context_refreshed: contextRefresh.applied === true,
  });
  return {
    schemaVersion: SCHEMA_VERSION,
    ...correction,
    workflow_id: String(task.workflow_id || ''),
    feedback_id: String(args.feedbackId || ''),
    plan_id: planId,
    creative_assets_modified: false,
    context_refresh: contextRefresh,
  };
}

function findMatchingShortFeedbackImpactPacket(root, task) {
  const feedbackId = String((((task || {}).pending_feedback || {}).feedback_id) || '');
  if (!feedbackId) return null;
  const directory = path.join(taskDir(root, task.workflow_id), 'result-packets');
  let names = [];
  try {
    names = fs.readdirSync(directory).filter(name => /^feedback_impact_sync.*\.result\.json$/.test(name));
  } catch (_) {
    return null;
  }
  const matches = names.map(name => {
    const file = path.join(directory, name);
    return { file, data: readJson(file), mtime: fs.statSync(file).mtimeMs };
  }).filter(item => item.data && !item.data.__error
    && String(item.data.workflow_id || '') === String(task.workflow_id || '')
    && String(item.data.stage_id || '') === 'feedback_impact_sync'
    && String(item.data.step_status || '') === 'completed'
    && String(item.data.feedback_id || '') === feedbackId
    && ['expression_only', 'current_brief', 'planning', 'structure'].includes(String(item.data.impact_level || '')))
    .sort((a, b) => b.mtime - a.mtime);
  if (!matches.length) return null;
  return { data: matches[0].data, relative_path: rel(root, matches[0].file) };
}

function shortFeedbackImpactFromPacket(packet, packetPath) {
  return {
    status: 'ok',
    feedback_id: String(packet.feedback_id || ''),
    impact_level: String(packet.impact_level || ''),
    affected_sections: Array.isArray(packet.affected_sections) ? packet.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(packet.affected_assets) ? packet.affected_assets : [],
    downstream_impact: packet.downstream_impact && typeof packet.downstream_impact === 'object' ? packet.downstream_impact : {},
    revision_groups: Array.isArray(packet.revision_groups) ? packet.revision_groups : [],
    next_stage_id: 'feedback_apply_patch',
    result_packet_path: String(packetPath || ''),
    analyzed_at: String(packet.completed_at || packet.updated_at || ''),
    recovered_from_result_packet: true,
  };
}

function buildShortFeedbackProposal(task, result, now = new Date().toISOString()) {
  const pending = task.pending_feedback || {};
  const feedbackId = String(result.feedback_id || pending.feedback_id || '');
  const proposed = result.proposed_plan && typeof result.proposed_plan === 'object' && !Array.isArray(result.proposed_plan)
    ? result.proposed_plan
    : {};
  const items = Array.isArray(pending.items) && pending.items.length
    ? pending.items
    : String(pending.text || '').trim() ? [{ feedback_id: feedbackId, text: String(pending.text || '').trim(), impact_level_hint: String(result.impact_level || '') }] : [];
  const requirements = Array.isArray(proposed.requirements) && proposed.requirements.length
    ? proposed.requirements.map((item, index) => ({
      requirement_id: String((item || {}).requirement_id || `${feedbackId}.requirement-${index + 1}`),
      text: String((item || {}).text || (item || {}).content || '').trim(),
      impact_level: String((item || {}).impact_level || result.impact_level || ''),
    })).filter(item => item.text)
    : items.map(item => ({
      requirement_id: String(item.feedback_id || ''),
      text: String(item.text || '').trim(),
      impact_level: String(item.impact_level_hint || result.impact_level || ''),
    }));
  return {
    schema_version: '1.0.0',
    proposal_id: String(proposed.proposal_id || `proposal.${feedbackId || 'unbound'}`),
    status: 'awaiting_user_confirmation',
    feedback_id: feedbackId,
    summary: String(proposed.summary || result.plan_summary || pending.text || '').trim(),
    execution_summary: String(proposed.execution_summary || result.handoff_summary || result.next_recommendation || ''),
    requirements,
    impact_level: String(result.impact_level || ''),
    affected_sections: Array.isArray(result.affected_sections) ? result.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(result.affected_assets) ? result.affected_assets : [],
    downstream_impact: result.downstream_impact && typeof result.downstream_impact === 'object' ? result.downstream_impact : {},
    revision_groups: Array.isArray(result.revision_groups) ? result.revision_groups : [],
    result_packet_path: String(result.result_packet_path || ''),
    proposed_at: now,
  };
}

function recoverShortFeedbackImpact(root, task, pending) {
  if (String(task.current_stage || '') !== 'feedback_apply_patch') return null;
  const packetPath = String((((task || {}).stage_execution || {}).result_packet) || '');
  const packetFile = resolveSafeProjectFile(root, packetPath);
  const packet = packetFile && fs.existsSync(packetFile) ? readJson(packetFile) : null;
  if (!packet || packet.__error
    || String(packet.stage_id || '') !== 'feedback_impact_sync'
    || String(packet.step_status || '') !== 'completed'
    || String(packet.feedback_id || '') !== String(pending.feedback_id || '')
    || !['expression_only', 'current_brief', 'planning', 'structure'].includes(String(packet.impact_level || ''))) {
    return null;
  }
  return {
    status: 'ok',
    feedback_id: String(packet.feedback_id || ''),
    impact_level: String(packet.impact_level || ''),
    affected_sections: Array.isArray(packet.affected_sections) ? packet.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(packet.affected_assets) ? packet.affected_assets : [],
    downstream_impact: packet.downstream_impact && typeof packet.downstream_impact === 'object' ? packet.downstream_impact : {},
    next_stage_id: 'feedback_apply_patch',
    result_packet_path: packetPath,
    analyzed_at: String(packet.completed_at || packet.updated_at || ''),
    recovered_from_result_packet: true,
  };
}

function reopenShortTaskForFeedback(task, now = new Date().toISOString()) {
  task.status = 'running';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'active';
  task.lifecycle.updated_at = now;
  task.lifecycle.completed_at = '';
  task.recommended_next = [];
  if (task.unit_lifecycle && typeof task.unit_lifecycle === 'object') {
    task.unit_lifecycle = {
      ...task.unit_lifecycle,
      status: 'active',
      updated_at: now,
    };
  }
}

function refreshActiveShortStageGuidance(root, task) {
  if (!isShortWritingWorkflow(task)) return { applied: false, reason: 'not_short_workflow' };
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== String(task.current_stage || '')) {
    return { applied: false, reason: 'stage_not_running' };
  }
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const sectionIndex = inferShortSectionIndex({ projectState, stageId: task.current_stage, scope: String(task.scope || '') }) || 1;
  task.scope = `第${sectionIndex}节`;
  delete execution.stage_context_packet;
  delete execution.execution_command;
  delete execution.quality_command;
  delete execution.resume_hint;
  delete execution.acceptance_metadata;
  attachShortStageExecutionGuidance(root, task, task.current_stage);
  return {
    applied: true,
    stage_id: task.current_stage,
    section_index: sectionIndex,
    execution_command: String(execution.execution_command || ''),
    context_packet: String(((execution.stage_context_packet || {}).packet_md) || ''),
  };
}

function reconcileShortProjectProgress(root, task, tpl) {
  const result = { applied: false, reason: 'not_applicable' };
  if (!isShortWritingWorkflow(task) || !tpl || !Array.isArray(tpl.stages)) return result;
  const stateFile = resolveSafeProjectFile(root, '追踪/private-short-extension/project-state.json');
  const state = stateFile && fs.existsSync(stateFile) ? readJson(stateFile) : null;
  if (!state || state.__error || !Array.isArray(state.accepted_sections)) return { ...result, reason: 'project_state_missing' };

  const accepted = state.accepted_sections
    .map((item) => ({
      section_index: Number((item || {}).section_index),
      anchor_path: String((item || {}).anchor_path || ''),
    }))
    .sort((left, right) => left.section_index - right.section_index);
  if (!accepted.length || accepted.some((item, index) => item.section_index !== index + 1)) {
    return { ...result, reason: 'accepted_section_sequence_incomplete' };
  }
  for (const item of accepted) {
    const expectedAnchor = `追踪/private-short-extension/section-${String(item.section_index).padStart(3, '0')}-anchor.json`;
    const anchorPath = item.anchor_path || expectedAnchor;
    const anchorFile = resolveSafeProjectFile(root, anchorPath);
    const anchor = anchorFile && fs.existsSync(anchorFile) ? readJson(anchorFile) : null;
    if (!anchor || anchor.__error || String(anchor.status || '') !== 'accepted') {
      return { ...result, reason: 'accepted_section_anchor_missing', section_index: item.section_index };
    }
  }

  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const plan = resolvePlannedSectionCount({ projectState: state, titleLock, outlineText });
  if (plan.status === 'missing') {
    return {
      ...result,
      blocked: true,
      status: 'blocked_short_section_plan_missing',
      findings: [{ field: 'planned_sections', message: '未找到已确认的全篇小节数；禁止自动生成计划外下一节。' }],
    };
  }
  if (plan.status === 'conflict') {
    return {
      ...result,
      blocked: true,
      status: 'blocked_short_section_plan_conflict',
      findings: [{ field: 'planned_sections', message: '项目状态、标题锁与小节大纲的总节数不一致。', evidence: plan.candidates }],
    };
  }
  if (plan.status === 'locked') {
    const progress = resolveShortPlanProgress({ plannedCount: plan.count, acceptedSections: accepted, currentSection: accepted.length });
    if (progress.status === 'outside_plan') {
      return {
        ...result,
        blocked: true,
        status: 'blocked_short_section_outside_plan',
        findings: [{ field: 'accepted_sections', message: '已采用小节超出锁定规划，不能继续自动生成下一节。', planned_sections: plan.count, accepted_sections: progress.accepted_sections }],
      };
    }
    const currentStage = String(task.current_stage || '');
    const completionStages = new Set(['next_section_brief', 'draft_next_section', 'draft_section', 'section_brief']);
    if (progress.completed && completionStages.has(currentStage)) {
      const targetStage = orderedStage(tpl, 'full_story_assembly') ? 'full_story_assembly' : '';
      if (!targetStage) {
        return { ...result, blocked: true, status: 'blocked_short_full_story_assembly_missing', findings: [{ field: 'full_story_assembly', message: '短篇工作流缺少全文组装阶段。' }] };
      }
      const previousStage = task.current_stage;
      task.current_stage = targetStage;
      task.current_step = targetStage;
      task.scope = '全篇';
      task.short_project_resume = {
        status: 'reconciled',
        reason: 'planned_story_complete',
        previous_stage: previousStage,
        target_stage: targetStage,
        accepted_section_count: accepted.length,
        planned_section_count: plan.count,
        latest_trusted_artifact: `追踪/private-short-extension/section-${String(plan.count).padStart(3, '0')}-anchor.json`,
        reconciled_at: new Date().toISOString(),
      };
      task.recommended_next = [{
        number: 1,
        action_id: 'run_current_stage',
        label: '组装已采用的全部小节（推荐）',
        description: `已完成锁定的 ${plan.count} 节；下一步只做确定性合稿，不再生成第${plan.count + 1}节。`,
      }];
      writeJson(stateFile, {
        ...state,
        status: 'all_sections_accepted',
        current_stage: targetStage,
        current_section_index: plan.count,
        remaining_sections: [],
        next_required_action: `组装已采用的 1-${plan.count} 节并进行全篇检查`,
        updated_at: new Date().toISOString(),
      });
      return { applied: true, ...task.short_project_resume };
    }
  }

  const statusMatch = /^section_(\d+)_brief_ready$/.exec(String(state.status || ''));
  const nextSection = accepted.length + 1;
  const nextTitle = (Array.isArray(titleLock.sections) ? titleLock.sections : [])
    .find((item) => Number((item || {}).section_index) === nextSection);
  const currentStage = String(task.current_stage || '');
  const staleAcceptedBrief = statusMatch && Number(statusMatch[1]) <= accepted.length;
  const needsTitleConfirmation = !nextTitle || nextTitle.confirmed !== true;
  const briefStage = nextSection === 1 ? 'first_section_brief' : 'next_section_brief';
  const briefPacketFile = resolveSafeProjectFile(root, `${task.task_dir}/result-packets/${briefStage}.result.json`);
  const briefPacket = briefPacketFile && fs.existsSync(briefPacketFile) ? readJson(briefPacketFile) : null;
  const nextBrief = `写作Brief_第${String(nextSection).padStart(3, '0')}节.md`;
  const nextBriefFreshness = checkBriefFreshness({
    projectRoot: root,
    briefPath: nextBrief,
    sectionIndex: nextSection,
    acceptedAnchorPath: nextSection > 1 ? `追踪/private-short-extension/section-${String(nextSection - 1).padStart(3, '0')}-anchor.json` : '',
  });
  const hasTrustedCurrentBrief = isTrustedShortResumePacket(briefPacket, task, briefStage, nextSection)
    && nextBriefFreshness.status === 'current';
  const hasTrustedCurrentDraft = ['draft_first_section', 'draft_next_section', 'draft_section', 'section_machine_gate', 'quality_gate', 'story_value_gate']
    .some((stageId) => {
      const file = resolveSafeProjectFile(root, `${task.task_dir}/result-packets/${stageId}.result.json`);
      const packet = file && fs.existsSync(file) ? readJson(file) : null;
      return isTrustedShortResumePacket(packet, task, stageId, nextSection);
    });
  if (((staleAcceptedBrief && !hasTrustedCurrentBrief) || (needsTitleConfirmation && !hasTrustedCurrentDraft && !hasTrustedCurrentBrief))
      && ['next_section_brief', 'draft_next_section', 'draft_section'].includes(currentStage)) {
    const targetStage = orderedStage(tpl, 'next_section_brief') ? 'next_section_brief' : 'section_brief';
    const previousStage = task.current_stage;
    task.current_stage = targetStage;
    task.current_step = targetStage;
    task.scope = `第${nextSection}节`;
    task.short_project_resume = {
      status: 'reconciled',
      reason: needsTitleConfirmation ? 'section_title_confirmation_required' : 'stale_accepted_brief',
      previous_stage: previousStage,
      target_stage: targetStage,
      accepted_section_count: accepted.length,
      next_section_index: nextSection,
      latest_trusted_artifact: `追踪/private-short-extension/section-${String(accepted.length).padStart(3, '0')}-anchor.json`,
      reconciled_at: new Date().toISOString(),
    };
    return { applied: true, ...task.short_project_resume };
  }
  if (hasTrustedCurrentBrief
      && ['draft_first_section', 'draft_next_section', 'draft_section'].includes(currentStage)
      && String(task.scope || '') === `第${nextSection}节`) {
    return { ...result, reason: 'workflow_already_at_trusted_stage', target_stage: currentStage };
  }
  if (!statusMatch || Number(statusMatch[1]) !== nextSection || String(state.current_stage || '') !== 'section_draft_ready') {
    return { ...result, reason: 'project_state_not_ready_for_draft' };
  }
  const latestBrief = `写作Brief_第${String(nextSection).padStart(3, '0')}节.md`;
  const briefFile = resolveSafeProjectFile(root, latestBrief);
  if (!briefFile || !fs.existsSync(briefFile)) return { ...result, reason: 'latest_brief_missing', latest_brief: latestBrief };

  const ordered = tpl.stages.map((item) => item.stage_id);
  const draftStage = nextSection === 1
    ? (ordered.includes('draft_first_section') ? 'draft_first_section' : 'draft_section')
    : (ordered.includes('draft_next_section') ? 'draft_next_section' : 'draft_section');
  const evidenceResume = resolveShortEvidenceResume(root, task, nextSection, ordered, draftStage);
  const targetStage = evidenceResume.target_stage;
  if (!targetStage || !ordered.includes(targetStage)) {
    return { ...result, reason: 'short_resume_target_missing', target_stage: targetStage };
  }
  if (String(task.current_stage || '') === targetStage && String(task.scope || '') === `第${nextSection}节`) {
    return { ...result, reason: 'workflow_already_at_trusted_stage', target_stage: targetStage };
  }

  const previousStage = task.current_stage;
  task.current_stage = targetStage;
  task.current_step = targetStage;
  task.scope = `第${nextSection}节`;
  task.short_project_resume = {
    status: 'reconciled',
    previous_stage: previousStage,
    target_stage: targetStage,
    accepted_section_count: accepted.length,
    next_section_index: nextSection,
    latest_brief: latestBrief,
    latest_trusted_artifact: evidenceResume.latest_trusted_artifact || latestBrief,
    evidence_stage: evidenceResume.evidence_stage,
    reconciled_at: new Date().toISOString(),
  };
  return { applied: true, ...task.short_project_resume };
}

function orderedStage(tpl, stageId) {
  return Boolean(tpl && Array.isArray(tpl.stages) && tpl.stages.some((item) => String((item || {}).stage_id || '') === stageId));
}

function resolveShortEvidenceResume(root, task, sectionIndex, ordered, draftStage) {
  const resultDir = resolveSafeProjectFile(root, `${task.task_dir}/result-packets`);
  const candidates = [
    { stage_id: 'quality_gate', target_stage: 'section_accept_anchor' },
    { stage_id: 'story_value_gate', target_stage: 'section_accept_anchor' },
    { stage_id: 'section_machine_gate', target_stage: 'quality_gate' },
    { stage_id: draftStage, target_stage: 'section_machine_gate' },
    { stage_id: sectionIndex === 1 ? 'first_section_brief' : 'next_section_brief', target_stage: draftStage },
  ];
  for (const candidate of candidates) {
    if (!ordered.includes(candidate.target_stage)) continue;
    const file = resultDir ? path.join(resultDir, `${candidate.stage_id}.result.json`) : '';
    const packet = file && fs.existsSync(file) ? readJson(file) : null;
    if (!isTrustedShortResumePacket(packet, task, candidate.stage_id, sectionIndex)) continue;
    return {
      target_stage: candidate.target_stage,
      evidence_stage: candidate.stage_id,
      latest_trusted_artifact: rel(root, file),
    };
  }
  return { target_stage: draftStage, evidence_stage: 'brief_ready', latest_trusted_artifact: `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md` };
}

function isTrustedShortResumePacket(packet, task, stageId, sectionIndex) {
  if (!packet || packet.__error) return false;
  if (String(packet.workflow_id || '') && String(packet.workflow_id) !== String(task.workflow_id || '')) return false;
  if (String(packet.stage_id || '') !== stageId) return false;
  if (Number(packet.current_section_index || 0) !== Number(sectionIndex)) return false;
  if (Array.isArray(packet.blocking_findings) && packet.blocking_findings.length > 0) return false;
  const verdicts = [packet.verification_result, packet.output_health_result, packet.machine_gate_result, packet.quality_gate_result, packet.story_value_result];
  return verdicts.some((value) => /^(pass|passed|accepted|approved|ok)$/i.test(String(value || '')));
}

function resolveAction(args) {
  const root = path.resolve(args.projectRoot);
  const task = readFocusedAuthority(root);
  if (!task) return { schemaVersion: SCHEMA_VERSION, status: 'no_active_task' };
  if (task.__error) return blockedFocusedAuthority(task);
  const lifecycleMigration = longformLifecycleMigrationBlock(task);
  if (lifecycleMigration) return resolveLegacyLongformMigrationChoice(root, task, args.input, lifecycleMigration);
  const reviewPlanValidation = validateTaskReviewPlan(root, task);
  if (reviewPlanValidation.blocked) return reviewPlanValidation.blocked;
  if (reviewPlanValidation.legacy) return blockedLegacyReviewPlan(task);
  const invariantFindings = validateTaskState(task, root);
  if (invariantFindings.length > 0) return blocked('blocked_state_invariant', invariantFindings);
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') return blockedTaskTemplate(registryCheck);
  const taskTemplate = registryCheck.template;
  const storedPending = task.pending_action && typeof task.pending_action === 'object' ? task.pending_action : {};
  const storedVisibleChoiceHash = String(storedPending.visible_choice_hash || '');
  const pending = task.pending_action && typeof task.pending_action === 'object'
    ? refreshedVisibleMenu(task, root)
    : {};
  if (storedVisibleChoiceHash && storedVisibleChoiceHash !== pending.visible_choice_hash) {
    pending.compatible_previous_visible_choice_hash = storedVisibleChoiceHash;
  }
  task.pending_action = pending;
  let selectedNumber = Number(args.input);
  let semanticContinuationBound = false;
  if (!Number.isInteger(selectedNumber) && shouldContinueConfirmedShortFeedback(task, args.input, pending)) {
    const recommended = (Array.isArray(pending.options) ? pending.options : [])
      .find(option => Number(option.number) === 1 || option.recommended === true);
    if (recommended) {
      selectedNumber = Number(recommended.number);
      const binding = visibleChoiceBinding(task, pending, root);
      args.pendingActionId = binding.pending_action_id;
      args.visibleChoiceHash = binding.visible_choice_hash;
      args.stateVersion = String(binding.state_version);
      args.bookRoot = binding.book_root;
      semanticContinuationBound = true;
    }
  }
  if (!Number.isInteger(selectedNumber)) {
    const classified = classifyFreeTextInput(task, args.input, pending);
    if (isShortWritingWorkflow(task) && ['current_artifact_feedback', 'scope_change'].includes(classified.classification)) {
      const tpl = taskTemplate;
      const feedbackStage = findStage(tpl, 'feedback_impact_sync');
      if (!feedbackStage) return blocked('blocked_short_feedback_stage_missing', '短篇工作流缺少反馈影响链阶段。');
      const now = new Date().toISOString();
      if (task.stage_execution && task.stage_execution.status === 'running') {
        task.stage_execution = {
          ...task.stage_execution,
          status: 'paused',
          stopped_at: now,
          stop_reason: 'user_feedback_requires_impact_analysis',
        };
      }
      const queuedFeedback = enqueueShortFeedback(root, task, String(args.input || ''), {
        receivedAt: now,
        classification: classified.classification,
        previousStage: String(task.current_stage || ''),
        sectionIndex: shortSectionIndex(root, task, String(task.current_stage || '')),
        scopeSnapshot: String(task.scope || ''),
      });
      if (queuedFeedback.status === 'feedback_queued') invalidateShortFeedbackAnalysis(task, now);
      reopenShortTaskForFeedback(task, now);
      if (classified.classification === 'current_artifact_feedback'
        && isExpressionOnlyShortFeedback(task.pending_feedback.text)) {
        const repairStage = findStage(tpl, 'section_repair_loop');
        if (!repairStage) return blocked('blocked_short_repair_stage_missing', '短篇工作流缺少当前节修订阶段。');
        task.short_feedback_impact = {
          status: 'ok',
          feedback_id: task.pending_feedback.feedback_id,
          impact_level: 'expression_only',
          next_stage_id: 'section_repair_loop',
          changed_assets: [],
          invalidates_brief: false,
          invalidates_draft: true,
          requires_structure_audit: false,
          downstream_revalidation: false,
          requires_reacceptance: true,
          feedback: task.pending_feedback.text,
          applied_at: now,
        };
        task.pending_action = null;
        const repairStart = maybeStartStageExecution(root, task, {
          action_id: 'repair_current_section_feedback',
          selected_number: 0,
          target_stage: 'section_repair_loop',
          risk_level: repairStage.risk_level || 'medium',
          execution_contract: { completion_boundary: 'stage_completed' },
        }, now, null);
        writeTaskState(root, task);
        if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
        appendHistory(root, 'short_expression_feedback_repair_started', {
          workflow_id: task.workflow_id || '',
          previous_stage: task.pending_feedback.previous_stage,
          feedback_id: task.pending_feedback.feedback_id,
        });
        return {
          schemaVersion: SCHEMA_VERSION,
          status: 'short_expression_feedback_repair_started',
          workflow_id: task.workflow_id || '',
          target_stage: 'section_repair_loop',
          feedback: task.pending_feedback,
          stage_execution: repairStart.stageExecution,
        };
      }
      task.pending_action = null;
      const startResult = maybeStartStageExecution(root, task, {
        action_id: 'analyze_user_feedback',
        selected_number: 0,
        target_stage: 'feedback_impact_sync',
        risk_level: 'medium',
        execution_contract: { completion_boundary: 'stop_before_creative_patch' },
      }, now, null);
      writeTaskState(root, task);
      if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
      appendHistory(root, 'short_feedback_impact_started', {
        workflow_id: task.workflow_id || '',
        previous_stage: task.pending_feedback.previous_stage,
        classification: classified.classification,
      });
      return {
        schemaVersion: SCHEMA_VERSION,
        status: 'short_feedback_impact_started',
        workflow_id: task.workflow_id || '',
        target_stage: 'feedback_impact_sync',
        feedback: task.pending_feedback,
        stage_execution: startResult.stageExecution,
      };
    }
    if (classified.classification === 'scope_change' && task.workflow_type === 'long_write') {
      applyLongformStructureFeedback(task, classified, args.input);
      writeTaskState(root, task);
      appendHistory(root, 'structure_feedback_replanned', {
        workflow_id: task.workflow_id || '',
        workflow_type: task.workflow_type || '',
        input: String(args.input || ''),
        impact_level: classified.impact_level,
        return_to: classified.return_to,
      });
      classified.downstream_effects = task.lifecycle_impact.downstream_effects;
    }
    return classified;
  }
  if (task.stage_execution && task.stage_execution.status === 'running') {
    const replayCarriesMenuBinding = Boolean(
      String(args.pendingActionId || '').trim()
      || String(args.visibleChoiceHash || '').trim()
      || String(args.stateVersion || '').trim(),
    );
    if (replayCarriesMenuBinding) {
      const bindingFailure = validateVisibleChoiceBinding(task, pending, args, root);
      if (bindingFailure) return bindingFailure;
      if (String(pending.status || '').toLowerCase() === 'resolved') {
        return blockedVisibleChoice(task, root, 'blocked_selection_resolved', '当前菜单已经处理，请使用当前阶段的新候选。');
      }
    }
    return resolveRunningStageControl(task, root, selectedNumber);
  }
  const bindingFailure = validateVisibleChoiceBinding(task, pending, args, root);
  if (bindingFailure) return bindingFailure;
  if (String(pending.status || '').toLowerCase() === 'resolved') {
    return blockedVisibleChoice(task, root, 'blocked_selection_resolved', '当前菜单已经处理，请重新显示最新候选。');
  }
  if (pending.expires_at && Date.now() > new Date(pending.expires_at).getTime()) {
    return blockedVisibleChoice(task, root, 'blocked_selection_expired', '当前数字候选已经过期，请重新显示最新候选。');
  }
  const option = (pending.options || []).find((item) => Number(item.number) === selectedNumber);
  if (!option) return blockedVisibleChoice(task, root, 'invalid_selection', `No pending action option for input: ${args.input}`);
  const semanticAction = String(option.action_id || option.action || '');
  if (semanticAction === 'inspect_current_state') {
    const menu = refreshedVisibleMenu(task, root);
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'current_task_inspected',
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      current_stage: String(task.current_stage || ''),
      current_scope: String(task.scope || ''),
      last_trusted_artifact: String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || task.last_trusted_artifact || ''),
      pending_action: menu,
      visible_response: pendingActionVisibleResponse(task, root, '当前进度已显示，原选择仍然有效。'),
    };
  }
  if (semanticAction === 'free_text') {
    const menu = refreshedVisibleMenu(task, root);
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'free_text_requested',
      workflow_id: String(task.workflow_id || ''),
      instruction: '请直接输入你的意见或新要求；只有这一步需要文字。',
      pending_action: menu,
      visible_response: { text: '请直接输入你的意见或新要求；只有这一步需要文字。' },
    };
  }
  if (semanticAction === 'replay_memory_projection') {
    return replayAcceptedMemoryProjection(root, task, taskTemplate, reviewPlanValidation);
  }
  if (semanticAction === 'request_revision_input') {
    const menu = refreshedVisibleMenu(task, root);
    const progress = shortRevisionQueueProgress(task, root);
    const currentSection = Number((progress || {}).current_section_index || shortSectionIndex(root, task, String(task.current_stage || '')) || 0);
    const sectionLabel = currentSection ? `第 ${currentSection} 节` : '当前节';
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'revision_input_requested',
      workflow_id: String(task.workflow_id || ''),
      current_scope: String(task.scope || ''),
      instruction: `请直接输入对${sectionLabel}的修改意见。${sectionLabel}保持为当前任务；修订并重新采用后自动继续下一个未完成小节。系统仅在后台同步受影响的设定、大纲和后续 Brief。`,
      pending_action: menu,
      visible_response: {
        render_mode: 'free_text_revision',
        status: 'revision_input_requested',
        text: `请直接输入对${sectionLabel}的修改意见。\n\n${sectionLabel}修订并重新采用后，自动继续下一个未完成任务。若意见影响设定、大纲或后续承接，系统会在后台同步后再回到${sectionLabel}，不会让你重新选择流程。`,
      },
    };
  }
  if (semanticAction === 'show_task_inbox') {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'task_inbox_requested',
      workflow_id: String(task.workflow_id || ''),
      execution_command: 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json',
      execution_workdir: '.',
    };
  }
  if (task.workflow_type === 'long_write' && option.action_id !== 'pause') {
    const symlinkValidation = validateLongformProjectTreeSymlinks(root);
    if (symlinkValidation) return symlinkValidation;
  }
  const shortEntryValidation = validateShortProseStageEntry(root, task, option.target_stage || '');
  if (shortEntryValidation) return shortEntryValidation;
  const selectedAt = new Date().toISOString();
  const selected = normalizeSelectedAction(option, selectedNumber, selectedAt, pending);
  selected.confirmation_input = String(args.input || '');
  task.last_selection = selected;
  task.pending_action = {
    ...pending,
    status: 'resolved',
    selected_number: selectedNumber,
    selected_action_id: selected.action_id,
    selected_at: selectedAt,
  };
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.updated_at = selectedAt;
  if (selected.action_id === 'pause') {
    task.status = 'paused';
    task.lifecycle.status = 'paused';
    if (task.stage_execution && task.stage_execution.status === 'running') {
      task.stage_execution = {
        ...task.stage_execution,
        status: 'paused',
        stopped_at: selectedAt,
        stop_reason: 'user_paused_from_numeric_menu',
      };
    }
  }
  const acceptedShortPlan = selected.target_stage === 'feedback_apply_patch'
    ? acceptShortPlanningDecision(root, task, selected)
    : { status: 'not_applicable', accepted_plan: null };
  const startResult = maybeStartStageExecution(root, task, selected, selectedAt, reviewPlanValidation);
  writeTaskState(root, task);
  appendHistory(root, 'resolved_action', {
    ...selected,
    workflow_id: task.workflow_id || '',
    workflow_type: task.workflow_type || '',
    current_stage: task.current_stage || '',
    current_step: task.current_step || '',
  });
  if (startResult.started) {
    appendHistory(root, 'stage_started', {
      workflow_id: task.workflow_id || '',
      workflow_type: task.workflow_type || '',
      current_stage: startResult.stageExecution.stage_id || task.current_stage || '',
      current_step: startResult.stageExecution.step_id || task.current_step || '',
    });
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    status: startResult.started ? 'stage_started' : startResult.contractBlocked ? 'stage_execution_contract_required' : 'resolved',
    selection_status: 'resolved',
    selected_number: selectedNumber,
    action: selected,
    action_id: selected.action_id,
    target_stage: selected.target_stage || '',
    execution_contract: selected.execution_contract,
    selection_locked: true,
    semantic_continuation_bound: semanticContinuationBound,
    accepted_plan: acceptedShortPlan.accepted_plan,
    stage_execution: startResult.stageExecution || null,
    pending_action: startResult.contractBlocked ? refreshedVisibleMenu(task, root) : null,
    next_candidates: startResult.contractBlocked ? ((startResult.visibleResponse || {}).options || []) : [],
    visible_response: startResult.visibleResponse || null,
  };
}

function resolveLegacyLongformMigrationChoice(root, task, input, menu) {
  const selected = Number(input);
  if (!Number.isInteger(selected) || selected < 1 || selected > 4) return menu;
  const option = (menu.options || []).find(candidate => Number(candidate.number) === selected) || {};
  if (selected === 1 || selected === 2) {
    const command = String(option.execution_command || '');
    if (!command) return menu;
    return {
      schemaVersion: SCHEMA_VERSION,
      status: selected === 1 ? 'legacy_longform_migration_selected' : 'legacy_longform_migration_preview_selected',
      workflow_id: String(task.workflow_id || ''),
      execution_command: command,
      completion_required_before_reply: true,
      interaction_contract: 'execute_completion_command_then_render_result',
      text: selected === 1
        ? '已选择迁移旧协议。现在执行迁移命令；完成后直接展示继任任务的当前阶段和 1/2/3/4 菜单。'
        : '现在只读查看迁移依据；不会修改任务或创作资产。',
    };
  }
  if (selected === 3) {
    const now = new Date().toISOString();
    task.status = 'paused';
    task.lifecycle = { ...(task.lifecycle || {}), status: 'paused', paused_at: now, updated_at: now };
    task.updated_at = now;
    atomicWriteJson(path.join(taskDir(root, task.workflow_id), 'task.json'), task);
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'legacy_longform_paused',
      workflow_id: String(task.workflow_id || ''),
      preserved_history: true,
      creative_files_changed: false,
      text: '旧长篇任务已暂停并原样保留。正文、大纲、设定均未修改。',
    };
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'free_text_requested',
    workflow_id: String(task.workflow_id || ''),
    text: '请直接输入迁移来源、希望保留的旧证据，或新的写作目标。',
  };
}

function shouldContinueConfirmedShortFeedback(task, input, pending) {
  if (!isShortWritingWorkflow(task)
    || String(task.current_stage || '') !== 'feedback_apply_patch'
    || !task.pending_feedback
    || !Array.isArray((pending || {}).options)
    || !(pending || {}).options.some(option => String(option.target_stage || '') === 'feedback_apply_patch')) return false;
  return /(?:根据|按照|按).{0,12}(?:已确认|上述|这个|当前).{0,12}(?:方案|影响|规划).{0,12}(?:继续|执行|修改|回写|回炉)|(?:继续|开始|执行).{0,12}(?:整篇回炉|整篇修改|规划回写|反馈回写)/u.test(String(input || ''));
}

function invalidateShortFeedbackAnalysis(task, now = new Date().toISOString()) {
  task.short_feedback_impact = null;
  if (task.feedback_revision_queue) {
    const queue = task.feedback_revision_queue;
    task.feedback_revision_history = [
      ...(Array.isArray(task.feedback_revision_history) ? task.feedback_revision_history : []),
      {
        queue_id: String(queue.queue_id || ''),
        feedback_id: String(queue.feedback_id || ''),
        current_section_index: Number(queue.current_section_index || 0) || null,
        completed_sections: Array.isArray(queue.completed_sections) ? queue.completed_sections : [],
        remaining_sections: (Array.isArray(queue.items) ? queue.items : [])
          .filter(item => String((item || {}).status || '') !== 'accepted')
          .map(item => Number((item || {}).section_index || 0))
          .filter(Boolean),
        snapshot_at: now,
        reason: 'new_feedback_received',
      },
    ].slice(-20);
    queue.interruption = {
      status: 'feedback_analysis_pending',
      section_index: Number(queue.current_section_index || 0) || null,
      at: now,
    };
    queue.checkpoints = [
      ...(Array.isArray(queue.checkpoints) ? queue.checkpoints : []),
      {
        event: 'feedback_received',
        section_index: Number(queue.current_section_index || 0) || null,
        at: now,
      },
    ].slice(-50);
    queue.updated_at = now;
  }
  task.last_selection = null;
  task.machine = task.machine || {};
  task.machine.completed_stages = (Array.isArray(task.machine.completed_stages) ? task.machine.completed_stages : [])
    .filter(stageId => !['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || '')));
  task.machine.remaining_stages = [
    'feedback_impact_sync',
    'feedback_apply_patch',
    ...(Array.isArray(task.machine.remaining_stages) ? task.machine.remaining_stages : [])
      .filter(stageId => !['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || ''))),
  ];
  task.machine.last_result_packet = '';
  task.machine.last_transition = 'short_feedback_reanalysis_required';
  const latest = String(((((task || {}).runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '');
  if (/\/feedback_(?:impact_sync|apply_patch)(?:\.|\.result)/.test(latest)) {
    task.runtime_guard.heartbeat.latest_trusted_artifact = '';
  }
}

function isShortWritingWorkflow(task) {
  return ['short_write', 'short_startup', 'private_short_startup'].includes(String((task || {}).workflow_type || ''));
}

function shortProjectState(root) {
  const state = readJson(path.join(root, '追踪/private-short-extension/project-state.json'));
  return state && !state.__error ? state : {};
}

function shortSectionIndex(root, task, stageId) {
  const revisionSection = currentShortFeedbackRevisionSection(task);
  if (revisionSection) return revisionSection;
  return inferShortSectionIndex({
    projectState: shortProjectState(root),
    stageId,
    scope: String((task || {}).scope || ''),
  });
}

function shortBriefPath(sectionIndex) {
  return `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
}

function shortAcceptedAnchorPath(sectionIndex) {
  if (sectionIndex <= 1) return '';
  return `追踪/private-short-extension/section-${String(sectionIndex - 1).padStart(3, '0')}-anchor.json`;
}

function validateShortProseStageEntry(root, task, targetStage) {
  if (!isShortWritingWorkflow(task) || !['draft_first_section', 'draft_next_section', 'draft_section'].includes(String(targetStage || ''))) return null;
  const sectionIndex = shortSectionIndex(root, task, targetStage);
  const check = checkShortProseEntry({
    projectRoot: root,
    briefPath: shortBriefPath(sectionIndex),
    sectionIndex,
    acceptedAnchorPath: shortAcceptedAnchorPath(sectionIndex),
  });
  if (check.status === 'pass') return null;
  return {
    schemaVersion: SCHEMA_VERSION,
    ...check,
    workflow_id: task.workflow_id || '',
    workflow_type: task.workflow_type || '',
    target_stage: targetStage,
  };
}

function recordShortBriefFreshness(root, task, result) {
  const stageId = String(result.stage_id || '');
  if (!isShortWritingWorkflow(task) || !['first_section_brief', 'next_section_brief', 'section_brief'].includes(stageId)) return null;
  const sectionIndex = shortSectionIndex(root, task, stageId);
  return writeBriefFreshnessSnapshot({
    projectRoot: root,
    briefPath: shortBriefPath(sectionIndex),
    sectionIndex,
    acceptedAnchorPath: shortAcceptedAnchorPath(sectionIndex),
  });
}

function validateShortFeedbackPatchResult(root, task, result, taskTemplate) {
  if (!isShortWritingWorkflow(task) || String(result.stage_id || '') !== 'feedback_apply_patch') return null;
  const tpl = taskTemplate;
  const stageDef = findStage(tpl, 'feedback_apply_patch') || {};
  const feedbackBinding = validateShortFeedbackBinding(task, result);
  if (feedbackBinding) return feedbackBinding;
  const sectionIndex = shortSectionIndex(root, task, 'feedback_apply_patch');
  const policy = resolveShortFeedbackPatch({
    result,
    allowedNext: stageDef.allowed_next || [],
    sectionIndex,
  });
  if (policy.status !== 'ok') {
    return blocked('blocked_feedback_impact_contract', [{
      field: 'feedback_impact',
      message: policy.message,
      details: policy,
    }]);
  }

  if (['planning', 'structure'].includes(policy.impact_level)
    && /^(?:全篇|整篇|全文|通篇)$/u.test(String(task.scope || ''))
    && !policy.affected_sections.length) {
    return blocked('blocked_feedback_revision_scope_missing', [{
      field: 'affected_sections',
      message: '全篇规划反馈必须明确受影响小节，不能默认落到最后一节。',
    }]);
  }

  if (policy.invalidates_brief) {
    const briefPath = shortBriefPath(sectionIndex);
    const briefFile = path.join(root, briefPath);
    if (fs.existsSync(briefFile)) {
      const freshness = checkBriefFreshness({
        projectRoot: root,
        briefPath,
        sectionIndex,
        acceptedAnchorPath: shortAcceptedAnchorPath(sectionIndex),
      });
      if (freshness.status === 'current') {
        return blocked('blocked_feedback_brief_not_invalidated', [{
          field: 'brief_invalidated',
          message: '上游规划声称已修改，但当前 Brief 仍与旧依赖一致；不得直接回炉正文。',
          brief_path: briefPath,
        }]);
      }
    }
  }

  result.next_stage_id = policy.next_stage_id;
  result.feedback_impact_policy = policy;
  task.short_feedback_impact = {
    ...policy,
    feedback_id: String((task.pending_feedback || {}).feedback_id || result.feedback_id || ''),
    feedback: String((task.pending_feedback || {}).text || result.feedback || result.user_feedback || ''),
    applied_at: new Date().toISOString(),
  };
  return null;
}

function validateShortFeedbackImpactResult(task, result) {
  if (!isShortWritingWorkflow(task) || String(result.stage_id || '') !== 'feedback_impact_sync') return null;
  const binding = validateShortFeedbackBinding(task, result);
  if (binding) return binding;
  if (!['expression_only', 'current_brief', 'planning', 'structure'].includes(String(result.impact_level || ''))) {
    return blocked('blocked_short_feedback_impact_missing', [{
      field: 'impact_level',
      message: '反馈影响分析缺少有效层级，不能进入规划回写。',
    }]);
  }
  if (['planning', 'structure'].includes(String(result.impact_level || ''))
    && /^(?:全篇|整篇|全文|通篇)$/u.test(String(task.scope || ''))
    && (!Array.isArray(result.affected_sections) || result.affected_sections.length === 0)) {
    return blocked('blocked_feedback_revision_scope_missing', [{
      field: 'affected_sections',
      message: '全篇规划影响分析必须列出受影响小节。',
    }]);
  }
  return null;
}

function recordShortFeedbackImpactResult(task, result) {
  if (!isShortWritingWorkflow(task)
    || String(result.stage_id || '') !== 'feedback_impact_sync'
    || String(result.step_status || '') !== 'completed') return null;
  const pending = task.pending_feedback || {};
  task.short_feedback_impact = {
    status: 'ok',
    feedback_id: String(result.feedback_id || pending.feedback_id || ''),
    impact_level: String(result.impact_level || ''),
    affected_sections: Array.isArray(result.affected_sections) ? result.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(result.affected_assets) ? result.affected_assets : [],
    downstream_impact: result.downstream_impact && typeof result.downstream_impact === 'object' ? result.downstream_impact : {},
    revision_groups: Array.isArray(result.revision_groups) ? result.revision_groups : [],
    next_stage_id: 'feedback_apply_patch',
    result_packet_path: String(result.result_packet_path || ''),
    analyzed_at: new Date().toISOString(),
  };
  task.proposed_plan = buildShortFeedbackProposal(task, result);
  return task.short_feedback_impact;
}

function validateShortFeedbackBinding(task, result) {
  const pending = task.pending_feedback || {};
  if (!String(pending.text || '').trim()) return null;
  const expected = String(pending.feedback_id || shortFeedbackId(pending.text, pending.received_at));
  const actual = String(result.feedback_id || '');
  if (!actual || actual !== expected) {
    return blocked('blocked_short_feedback_identity_mismatch', [{
      field: 'feedback_id',
      message: '反馈回执不属于当前待处理意见，禁止复用上一轮反馈结果。',
      expected,
      actual,
    }]);
  }
  return null;
}

function shortFeedbackId(text, receivedAt) {
  return `feedback-${crypto.createHash('sha256').update(`${String(receivedAt || '')}\n${String(text || '').trim()}`, 'utf8').digest('hex').slice(0, 16)}`;
}

function pendingFeedbackSectionIndex(pending) {
  const explicit = Number((pending || {}).section_index || 0);
  if (Number.isInteger(explicit) && explicit > 0) return explicit;
  const match = `${String((pending || {}).scope_snapshot || '')}\n${String((pending || {}).text || '')}`.match(/第\s*0*(\d+)\s*节/u);
  return match ? Number(match[1]) : 0;
}

function isExpressionOnlyShortFeedback(text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (/(扩容|缩容|增加.{0,4}(节|情节)|删除.{0,4}(节|情节)|合并.{0,4}(节|情节)|重排|改大纲|改设定|人物动机|核心反转|主线|结局)/u.test(value)) return false;
  return /(AI\s*味|ai\s*味|破折号|省略号|标点|句式|用词|措辞|语气|口吻|对白.{0,4}(自然|生硬)|短句.{0,4}(太多|过密)|复读|重复表达)/u.test(value);
}

function shortFeedbackReconcileBlock(task, result) {
  if (!isShortWritingWorkflow(task)) return null;
  const stageId = String((result || {}).stage_id || '');
  if (['feedback_impact_sync', 'feedback_apply_patch', 'section_repair_loop'].includes(stageId)) return null;
  const pending = task.pending_feedback || {};
  if (!String(pending.text || '').trim()) return null;
  const expectedId = String(pending.feedback_id || shortFeedbackId(pending.text, pending.received_at));
  const impact = task.short_feedback_impact || {};
  return blocked('blocked_short_feedback_unreconciled', [{
    field: 'pending_feedback',
    message: '当前短篇意见尚未完成修订、复检与重新采用；影响分析本身不等于反馈已解决，不能启动下一节或采用旧结果。',
    feedback_id: expectedId,
    impact_status: String(impact.status || ''),
    current_stage: String(task.current_stage || ''),
  }]);
}

function validateVisibleChoiceBinding(task, pending, args, root) {
  const current = visibleChoiceBinding(task, pending, root);
  if (!args.pendingActionId || !args.visibleChoiceHash || args.stateVersion === '') {
    return blockedVisibleChoice(task, root, 'blocked_missing_visible_choice_binding', '数字选择必须绑定当前可见菜单，请重新显示最新候选。');
  }
  const requestedStateVersion = Number(args.stateVersion);
  if (!Number.isInteger(requestedStateVersion)
    || requestedStateVersion !== current.state_version
    || String(args.pendingActionId) !== current.pending_action_id) {
    return blockedVisibleChoice(task, root, 'blocked_stale_visible_choice', '当前菜单已经更新，请按最新候选重新选择。');
  }
  if (String(args.visibleChoiceHash) !== current.visible_choice_hash
    && String(args.visibleChoiceHash) !== String((pending || {}).compatible_previous_visible_choice_hash || '')) {
    return blockedVisibleChoice(task, root, 'blocked_visible_choice_hash_mismatch', '当前候选校验不一致，请重新显示最新候选。');
  }
  const taskBookRoot = resolveProjectRootReference(task.book_root, root);
  const pendingBookRoot = resolveProjectRootReference(pending.book_root, root);
  const requestedBookRoot = resolveProjectRootReference(args.bookRoot, root);
  if (taskBookRoot !== root || pendingBookRoot !== root || requestedBookRoot !== root) {
    return blockedVisibleChoice(task, root, 'blocked_pending_action_project_mismatch', '当前候选不属于这个书目项目，请重新显示最新候选。');
  }
  return null;
}

function visibleChoiceBinding(task, pending, root) {
  return {
    pending_action_id: String((pending || {}).id || ''),
    visible_choice_hash: String((pending || {}).visible_choice_hash || ''),
    state_version: Number(task.state_version || 0),
    book_root: root,
  };
}

function refreshedVisibleMenu(task, root) {
  const progress = shortRevisionQueueProgress(task, root);
  const sourcePending = task.pending_action && typeof task.pending_action === 'object'
    ? { ...task.pending_action, options: Array.isArray(task.pending_action.options) ? task.pending_action.options.map(option => ({ ...option })) : [] }
    : {};
  if (progress) {
    const draftStages = new Set(['draft_first_section', 'draft_section', 'draft_next_section']);
    const queueItem = (Array.isArray((task.feedback_revision_queue || {}).items) ? task.feedback_revision_queue.items : [])
      .find(item => Number((item || {}).section_index || 0) === Number(progress.current_section_index || 0));
    const revisionPrimary = draftStages.has(String(task.current_stage || ''))
      && String((queueItem || {}).prose_status || '') === 'pending_recheck'
      ? buildShortDraftPendingAction(findStage(resolvedTemplateForTask(task).template || {}, task.current_stage), task).options[0]
      : null;
    if (revisionPrimary) {
      const sectionIndex = Number(progress.current_section_index || 0);
      sourcePending.question = `第 ${sectionIndex || ''} 节已有正文，当前进入复检与局部回炉`.replace('第  节', '当前小节');
    }
    const primary = revisionPrimary
      || sourcePending.options.find(option => !['inspect_current_state', 'pause', 'free_text', 'show_task_inbox'].includes(String(option.action_id || option.action || '')))
      || sourcePending.options[0];
    sourcePending.options = [
      primary,
      {
        action_id: 'request_revision_input',
        label: `修改第 ${progress.current_section_index} 节；完成后继续后续任务`,
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        action_id: 'inspect_current_state',
        label: `查看本轮修订队列与依据（${progress.remaining} 项）`,
        frontend_surface: 'workflow_queue_detail',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        action_id: 'pause',
        label: '暂停并保存断点',
        risk_level: 'low',
        requires_user_confirm: false,
      },
    ].filter(Boolean);
  }
  const pending = task.pending_action && typeof task.pending_action === 'object'
    ? decoratePendingAction({ ...sourcePending, visible_choice_hash: '' })
    : {};
  return {
    ...pending,
    ...visibleChoiceBinding(task, pending, root),
  };
}

function pendingActionVisibleResponse(task, root, intro = '') {
  const pending = refreshedVisibleMenu(task, root);
  const progress = shortRevisionQueueProgress(task, root);
  const options = (Array.isArray(pending.options) ? pending.options : []).slice(0, 4).map((option, index) => ({
    ...option,
    number: index + 1,
    interaction_mode: 'execute_command',
    execution_workdir: '.',
    execution_command: [
      'node scripts/workflow-state-machine.js resolve-action',
      '--project-root .',
      `--input ${index + 1}`,
      `--pending-action-id ${shellQuote(pending.pending_action_id || pending.id || '')}`,
      `--visible-choice-hash ${shellQuote(pending.visible_choice_hash || '')}`,
      `--state-version ${Number(pending.state_version || task.state_version || 0)}`,
      '--book-root .',
      '--json',
    ].join(' '),
  }));
  const visiblePending = { ...pending, options };
  return {
    render_mode: 'text_numbers',
    status: 'workflow_choice_required',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: pending.free_text_enabled !== false,
    options,
    work_queue: progress,
    text: renderPendingActionText(visiblePending, [String(intro || '').trim(), String((progress || {}).text || '').trim()].filter(Boolean).join('\n\n')),
  };
}

function shortRevisionQueueProgress(task, root) {
  if (!task || !task.feedback_revision_queue) return null;
  const lock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  return buildShortRevisionQueueProgress(task, Array.isArray(lock.sections) ? lock.sections : []);
}

function shortRevisionTaskOverview(task, root) {
  if (!task || !task.feedback_revision_queue) return null;
  const lock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const workingTitle = String(projectState.working_title || projectState.title || '').trim();
  const overview = buildShortRevisionTaskOverview(
    {
      ...task,
      task_display_title: workingTitle ? `整篇回炉《${workingTitle}》` : String(task.user_goal || '整篇回炉'),
      user_goal: workingTitle ? `整篇回炉《${workingTitle}》` : String(task.user_goal || '整篇回炉'),
    },
    Array.isArray(lock.sections) ? lock.sections : [],
    Number(projectState.planned_sections || 0),
  );
  if (!overview) return null;
  const pending = refreshedVisibleMenu(task, root);
  const pause = (Array.isArray(pending.options) ? pending.options : []).find(option => String(option.action_id || '') === 'pause');
  const pauseCommand = pause ? [
    'node scripts/workflow-state-machine.js resolve-action',
    '--project-root .',
    `--input ${Number(pause.number || 4)}`,
    `--pending-action-id ${shellQuote(pending.pending_action_id || pending.id || '')}`,
    `--visible-choice-hash ${shellQuote(pending.visible_choice_hash || '')}`,
    `--state-version ${Number(pending.state_version || task.state_version || 0)}`,
    '--book-root .',
    '--json',
  ].join(' ') : '';
  const options = [
    {
      number: 1,
      action_id: 'open_current_subtask',
      label: `继续当前子任务：${String(((overview || {}).current_subtask || {}).label || '进入下一执行点')}（推荐）`,
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: 'node scripts/workflow-state-machine.js next-candidates --project-root . --json',
    },
    {
      number: 2,
      action_id: 'inspect_task_subtasks',
      label: '查看全部子任务与检查点',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: 'node scripts/workflow-state-machine.js task-overview --project-root . --json',
    },
    {
      number: 3,
      action_id: 'request_task_revision_input',
      label: '调整整篇回炉任务',
      interaction_mode: 'semantic_only',
    },
    {
      number: 4,
      action_id: 'pause',
      label: '暂停并保存断点',
      interaction_mode: pauseCommand ? 'execute_command' : 'semantic_only',
      execution_workdir: '.',
      execution_command: pauseCommand,
    },
  ];
  return {
    ...overview,
    render_mode: 'task_overview_then_subtask',
    selection_contract: 'enter_task_before_subtask',
    options,
    visible_response: {
      render_mode: 'text_numbers',
      status: 'workflow_task_overview',
      options,
      text: `${overview.text}\n\n${options.map(option => `${option.number}. ${option.label}`).join('\n')}\n\n回复数字选择。`,
    },
  };
}

function workflowTaskOverview(task, root) {
  const revisionOverview = shortRevisionTaskOverview(task, root);
  if (revisionOverview) return revisionOverview;
  const registryCheck = resolvedTemplateForTask(task);
  if (!registryCheck || registryCheck.status !== 'ok') return null;
  const overview = buildWorkflowTaskOverview(task, registryCheck.template);
  if (!overview) return null;
  const options = [
    {
      number: 1,
      action_id: 'open_current_subtask',
      label: `进入当前子任务：${String(((overview || {}).current_subtask || {}).label || '继续当前阶段')}（推荐）`,
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: 'node scripts/workflow-state-machine.js next-candidates --project-root . --json',
    },
    {
      number: 2,
      action_id: 'inspect_task_subtasks',
      label: '查看全部阶段、完成条件与检查点',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: 'node scripts/workflow-state-machine.js task-overview --project-root . --json',
    },
    {
      number: 3,
      action_id: 'request_task_revision_input',
      label: '调整当前任务目标或范围',
      interaction_mode: 'semantic_only',
    },
    {
      number: 4,
      action_id: 'pause',
      label: '暂停并保存断点',
      interaction_mode: 'semantic_only',
    },
  ];
  return {
    ...overview,
    render_mode: 'task_overview_then_subtask',
    selection_contract: 'enter_task_before_subtask',
    options,
    visible_response: {
      render_mode: 'text_numbers',
      status: 'workflow_task_overview',
      options,
      text: `${overview.text}\n\n${options.map(option => `${option.number}. ${option.label}`).join('\n')}\n\n回复数字选择。`,
    },
  };
}

function blockedVisibleChoice(task, root, status, message) {
  return {
    schemaVersion: SCHEMA_VERSION,
    status,
    selection_status: 'blocked',
    findings: [{ field: status, message }],
    refreshed_menu: refreshedVisibleMenu(task, root),
  };
}

function portableProjectCommand(command, root) {
  let value = String(command || '');
  const projectRoot = String(root || '');
  if (!value || !projectRoot) return value;
  for (const token of [JSON.stringify(projectRoot), shellQuote(projectRoot), projectRoot]) {
    value = value.split(`--project-root ${token}`).join('--project-root .');
  }
  return value;
}

function runningStageResume(task, root) {
  const execution = task && task.stage_execution && task.stage_execution.status === 'running'
    ? task.stage_execution
    : null;
  if (!execution) return null;
  const portableExecution = {
    ...execution,
    execution_workdir: '.',
    execution_command: portableProjectCommand(execution.execution_command, root),
    quality_command: portableProjectCommand(execution.quality_command, root),
    stage_completion_command: portableProjectCommand(execution.stage_completion_command, root),
    context_read_command: portableProjectCommand(execution.context_read_command, root),
    completion_required_before_reply: true,
    stage_completion_contract: 'read_context_edit_write_set_execute_completion_command_consume_result_same_turn',
    execution_sequence: ['read_context', 'edit_write_set', 'execute_completion_command', 'consume_result_presentation'],
  };
  const terminalReplyAllowedOn = ['workflow_choice_required', 'workflow_completed', 'host_tool_call_failed_after_retry', 'retry_budget_exhausted'];
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'stage_execution_resume_ready',
    selection_status: 'resume',
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || ''),
    current_stage: String(task.current_stage || ''),
    current_step: String(task.current_step || ''),
    interaction_mode: 'resume_stage',
    execution_workdir: '.',
    execution_command: portableExecution.execution_command || '',
    resume_hint: String(portableExecution.resume_hint || ''),
    stage_execution: portableExecution,
    completion_required_before_reply: true,
    terminal_reply_allowed_on: terminalReplyAllowedOn,
    visible_response: {
      render_mode: 'silent_resume',
      status: 'stage_execution_resume_ready',
      text: '',
      selection_contract: 'resume_running_stage',
      interaction_mode: 'resume_stage',
      execution_workdir: '.',
      execution_command: portableExecution.execution_command || '',
      context_read_command: portableExecution.context_read_command || '',
      resume_hint: String(portableExecution.resume_hint || ''),
      requires_user_confirm: false,
      completion_required_before_reply: true,
      terminal_reply_allowed_on: terminalReplyAllowedOn,
    },
  };
}

function runningStageDisplayName(stageId) {
  const names = {
    feedback_impact_sync: '分析反馈影响',
    feedback_apply_patch: '回写已确认的设定与小节大纲',
    section_brief_ready: '生成当前小节写作提要',
    section_draft_loop: '写作当前小节',
    section_repair_loop: '修订当前小节',
    final_check: '完成全篇最终检查',
  };
  return names[String(stageId || '')] || '继续当前任务';
}

function runningStageControlMenu(task, root, prefix = '') {
  const command = (number) => `node scripts/workflow-state-machine.js resolve-action --project-root . --input ${number} --json`;
  const progress = shortRevisionQueueProgress(task, root);
  const labels = [
    '继续当前阶段（推荐）',
    progress ? `查看本轮修订队列与依据（${progress.remaining} 项）` : '查看当前进度与依据',
    '暂停并保存断点',
    '输入其他要求',
  ];
  const options = labels.map((label, index) => ({
    number: index + 1,
    label,
    action: ['resume_running_stage', 'inspect_running_stage', 'pause_running_stage', 'free_text'][index],
    interaction_mode: index < 3 ? 'execute_command' : 'semantic_only',
    execution_workdir: index < 3 ? '.' : '',
    execution_command: index < 3 ? command(index + 1) : '',
    display: `${index + 1}. ${label}`,
  }));
  const execution = task.stage_execution || {};
  const intro = [
    `${prefix ? `${prefix}\n\n` : ''}当前任务停在“${runningStageDisplayName(execution.stage_id || task.current_stage)}”阶段。`,
    String((progress || {}).text || ''),
  ].filter(Boolean).join('\n\n');
  return {
    render_mode: 'text_numbers',
    status: 'running_stage_waiting_choice',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    options,
    text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择，也可以直接输入你的意见。`,
  };
}

function resolveRunningStageControl(task, root, selectedNumber) {
  if (selectedNumber === 1) return runningStageResume(task, root);
  if (selectedNumber === 2) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'current_stage_inspected',
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      current_stage: String(task.current_stage || ''),
      current_step: String(task.current_step || ''),
      current_scope: String(task.scope || ''),
      last_trusted_artifact: String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || task.last_trusted_artifact || ''),
      stage_execution: task.stage_execution,
      visible_response: runningStageControlMenu(task, root, '当前进度与依据已显示；原来的四个选择仍然有效。'),
    };
  }
  if (selectedNumber === 3) {
    const now = new Date().toISOString();
    task.status = 'paused';
    task.lifecycle = normalizeLifecycle(task);
    task.lifecycle.status = 'paused';
    task.lifecycle.updated_at = now;
    task.stage_execution = {
      ...task.stage_execution,
      status: 'paused',
      stopped_at: now,
      stop_reason: 'user_paused_from_running_stage_menu',
    };
    writeTaskState(root, task);
    if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
    appendHistory(root, 'running_stage_paused', {
      workflow_id: task.workflow_id || '',
      workflow_type: task.workflow_type || '',
      current_stage: task.current_stage || '',
    });
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'stage_paused',
      workflow_id: String(task.workflow_id || ''),
      current_stage: String(task.current_stage || ''),
      visible_response: {
        render_mode: 'text',
        status: 'stage_paused',
        text: '当前阶段已暂停，断点和暂存内容均已保留。下次进入 novel-assistant 时可从这里恢复。',
      },
    };
  }
  if (selectedNumber === 4) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'free_text_requested',
      workflow_id: String(task.workflow_id || ''),
      instruction: '请直接输入你的意见、范围调整或新目标；当前阶段会保留在可信断点。',
      visible_response: {
        render_mode: 'text',
        status: 'free_text_requested',
        text: '请直接输入你的意见、范围调整或新目标；当前阶段会保留在可信断点。',
      },
    };
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'invalid_running_stage_selection',
    workflow_id: String(task.workflow_id || ''),
    visible_response: runningStageControlMenu(task, root, '请选择 1、2、3、4，或直接输入你的意见。'),
  };
}

function maybeStartStageExecution(root, task, selected, selectedAt, reviewPlan) {
  if (selected.action_id === 'pause') return { started: false, stageExecution: null };

  const targetStage = selected.target_stage || task.current_stage || task.current_step || '';
  if (!targetStage) return { started: false, stageExecution: null };

  const activeReviewBatch = targetStage === 'evidence_scan' ? currentReviewBatch(task.review_batches) : null;
  const activePlanEntry = activeReviewBatch && reviewPlan && reviewPlan.planEntriesById
    ? reviewPlan.planEntriesById.get(activeReviewBatch.plan_entry_id)
    : null;
  const activeBatchRange = activePlanEntry ? activePlanEntry.range : activeReviewBatch ? activeReviewBatch.range : '';
  const expectedResultPacket = activeReviewBatch
    ? expectedReviewBatchResultPacket(task, activeReviewBatch.id)
    : expectedResultPacketPath(task, targetStage, root);
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') return blockedTaskTemplate(registryCheck);
  const tpl = registryCheck.template;
  const stageDef = findStage(tpl, targetStage) || {};
  const unitScope = String(activeBatchRange || task.scope || ((task.lifecycle || {}).scope) || ((task.unit_lifecycle || {}).current_scope) || targetStage);
  const workUnitId = stageWorkUnitId(task, targetStage, unitScope);
  const attemptChain = preservePreviousStageAttempt(task, workUnitId, selectedAt);
  const confirmationContext = stageDef.requires_user_confirm
    ? buildConfirmationContext(task, selected, targetStage, selectedAt)
    : null;
  task.current_stage = targetStage;
  task.current_step = targetStage;
  task.status = 'running';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'active';
  task.lifecycle.updated_at = selectedAt;
  task.stage_execution = {
    status: 'running',
    stage_attempt_id: createStageAttemptId(task.workflow_id, targetStage),
    work_unit_id: workUnitId,
    work_unit_scope: unitScope,
    attempt_no: attemptChain.attempt_no,
    supersedes_attempt_id: attemptChain.supersedes_attempt_id,
    repeat_scope: 'current_unit_only',
    stage_id: targetStage,
    step_id: targetStage,
    action_id: selected.action_id,
    selected_number: selected.selected_number,
    started_at: selectedAt,
    expected_result_packet: expectedResultPacket,
    owner_module: stageDef.owner_module || '',
    stage_description: String(stageDef.description || ''),
    required_inputs: Array.isArray(stageDef.required_inputs) ? stageDef.required_inputs.slice() : [],
    lifecycle_node: stageDef.lifecycle_node || '',
    asset_target: { ...(stageDef.asset_target || {}) },
    review_requirement: { ...(stageDef.review_requirement || {}) },
    write_set: Array.isArray(stageDef.write_set) ? stageDef.write_set.slice() : [],
    scheduling_contract: tpl.scheduling_contract && typeof tpl.scheduling_contract === 'object'
      ? JSON.parse(JSON.stringify(tpl.scheduling_contract))
      : null,
    transition_contract: stageDef.transition_contract && typeof stageDef.transition_contract === 'object'
      ? JSON.parse(JSON.stringify(stageDef.transition_contract))
      : { allowed_next: Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next.slice() : [] },
    interaction_contract: stageDef.interaction_contract && typeof stageDef.interaction_contract === 'object'
      ? JSON.parse(JSON.stringify(stageDef.interaction_contract))
      : null,
    memory_contract: stageDef.memory_contract && typeof stageDef.memory_contract === 'object'
      ? JSON.parse(JSON.stringify(stageDef.memory_contract))
      : null,
    risk_level: stageDef.risk_level || selected.risk_level || 'low',
    requires_user_confirm: Boolean(stageDef.requires_user_confirm),
    confirmation_token: confirmationContext ? confirmationContext.confirmation_token : '',
    confirmation_context: confirmationContext,
    completion_boundary: selected.execution_contract ? selected.execution_contract.completion_boundary : '',
    batch_id: activeReviewBatch ? activeReviewBatch.id : '',
    batch_scope: activeBatchRange,
    resume_hint: `等待 ${targetStage} result packet；不要回到待确认状态。`,
    host_execution_mode: 'cooperative_interactive',
    execution_boundary: normalizeExecutionBoundary({ host_execution_mode: 'cooperative_interactive' }),
  };
  attachShortStageExecutionGuidance(root, task, targetStage);
  attachLongStageExecutionGuidance(root, task, targetStage);
  attachStageMemoryGuidance(root, task, targetStage);
  const executionContract = validateStartedStageExecutionContract(task, targetStage);
  if (executionContract.status === 'missing') {
    return blockStageExecutionContract(root, task, targetStage, executionContract);
  }
  const baseline = captureCanonicalBaseline(root, task);
  if (baseline.declared_write_set.length > 0) task.canonical_write_baseline = baseline;
  if (task.workflow_type === 'long_write') {
    task.stage_execution.write_snapshot = captureStageWriteSnapshot(root, task, expectedResultPacket);
  }
  if (confirmationContext) {
    selected.confirmation_token = confirmationContext.confirmation_token;
    selected.confirmation_expires_at = confirmationContext.expires_at;
    task.last_selection = selected;
  }

  const previousTransition = String((((task || {}).machine || {}).last_transition) || '');
  task.machine = normalizeMachine(task, tpl);
  task.machine.completed_stages = task.machine.completed_stages.filter(stageId => stageId !== targetStage);
  task.machine.remaining_stages = [
    targetStage,
    ...task.machine.remaining_stages.filter(stageId => stageId !== targetStage),
  ];
  task.machine.last_execution_event = 'stage_started';
  task.machine.last_transition = selected.action_id === 'auto_continue_internal' && previousTransition
    ? previousTransition
    : 'stage_started';
  task.machine.next_stop_reason = 'stage_running_waiting_result_packet';
  task.machine.allowed_actions = ['await_result_packet', 'pause'];

  task.runtime_guard = task.runtime_guard || buildRuntimeGuard({ projectRoot: root }, task.workflow_id || 'workflow', selectedAt);
  task.runtime_guard.heartbeat = {
    ...(task.runtime_guard.heartbeat || {}),
    updated_at: selectedAt,
    latest_trusted_artifact: String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '') === expectedResultPacket
      ? ''
      : String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || ''),
    current_batch: activeReviewBatch ? activeReviewBatch.range : targetStage,
    workflow_id: task.workflow_id || '',
  };
  task.runtime_guard.checkpoint_policy = {
    ...(task.runtime_guard.checkpoint_policy || {}),
    resume_from: targetStage,
    checkpoint_path: durableTaskSnapshotPath(task),
    expected_result_packet: expectedResultPacket,
    project_root: '.',
  };

  return { started: true, stageExecution: task.stage_execution };
}

function stageWorkUnitId(task, stageId, scope) {
  const identity = [
    String((task || {}).workflow_id || 'workflow'),
    String(stageId || 'stage'),
    String(scope || 'current-scope'),
  ].join('|');
  return `wu-${crypto.createHash('sha256').update(identity).digest('hex').slice(0, 16)}`;
}

function preservePreviousStageAttempt(task, nextWorkUnitId, preservedAt) {
  const previous = task && task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : null;
  const history = Array.isArray((task || {}).stage_attempt_history)
    ? task.stage_attempt_history.slice()
    : [];
  if (previous && previous.stage_attempt_id
    && !history.some(item => String((item || {}).stage_attempt_id || '') === String(previous.stage_attempt_id))) {
    history.push({
      stage_attempt_id: String(previous.stage_attempt_id || ''),
      work_unit_id: String(previous.work_unit_id || ''),
      stage_id: String(previous.stage_id || ''),
      status: String(previous.status || ''),
      expected_result_packet: String(previous.expected_result_packet || ''),
      accepted_result_packet: String(previous.accepted_result_packet || previous.result_packet || ''),
      started_at: String(previous.started_at || ''),
      preserved_at: String(preservedAt || new Date().toISOString()),
    });
  }
  task.stage_attempt_history = history.slice(-100);
  const sameUnitAttempts = task.stage_attempt_history
    .filter(item => String((item || {}).work_unit_id || '') === String(nextWorkUnitId || ''));
  const latest = sameUnitAttempts[sameUnitAttempts.length - 1] || null;
  return {
    attempt_no: sameUnitAttempts.length + 1,
    supersedes_attempt_id: latest ? String(latest.stage_attempt_id || '') : '',
  };
}

function validateStartedStageExecutionContract(task, stageId) {
  const workflowType = String((task || {}).workflow_type || '');
  const required = isShortWritingWorkflow(task)
    ? SHORT_EXECUTABLE_STAGE_CONTRACTS.has(String(stageId || ''))
    : workflowType === 'long_write'
      ? LONG_EXECUTABLE_STAGE_CONTRACTS.has(String(stageId || ''))
      : false;
  if (!required) return { status: 'not_required' };
  const execution = (task || {}).stage_execution || {};
  if (((execution.memory_context || {}).blocking) === true) {
    return {
      status: 'missing',
      reason: String(((execution.memory_context || {}).status) || '当前阶段要求的记忆上下文不可用。'),
    };
  }
  if (String(execution.execution_command || '').trim() || String(execution.context_read_command || '').trim()) return { status: 'ok' };
  return {
    status: 'missing',
    reason: String(execution.context_packet_warning || '当前阶段没有绑定可执行命令或受控上下文包。'),
  };
}

function blockStageExecutionContract(root, task, targetStage, finding) {
  const now = new Date().toISOString();
  task.status = 'paused_after_step';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'paused';
  task.lifecycle.updated_at = now;
  task.stage_execution = {
    ...(task.stage_execution || {}),
    status: 'contract_blocked',
    stopped_at: now,
    stop_reason: 'stage_execution_contract_missing',
    contract_finding: finding,
  };
  task.pending_action = decoratePendingAction({
    id: `pa-stage-contract-${String(targetStage || 'unknown')}`,
    question: '当前阶段缺少完整执行条件，尚未启动。',
    options: [
      { number: 1, action_id: 'retry_stage_contract', target_stage: targetStage, label: '重新准备当前阶段（推荐）', risk_level: 'low' },
      { number: 2, action_id: 'inspect_current_state', label: '查看缺失条件与当前进度', risk_level: 'low' },
      { number: 3, action_id: 'pause', label: '暂停并保存断点', risk_level: 'low' },
      { number: 4, action_id: 'free_text', label: '输入其他要求', risk_level: 'low' },
    ],
    free_text_enabled: true,
  });
  bindPendingActionToNextState(task, root);
  return {
    started: false,
    stageExecution: task.stage_execution,
    contractBlocked: true,
    visibleResponse: pendingActionVisibleResponse(task, root, `无法安全启动“${runningStageDisplayName(targetStage)}”：${finding.reason}`),
  };
}

function attachStageMemoryGuidance(root, task, targetStage) {
  const execution = task.stage_execution || {};
  execution.memory_contract_version = 2;
  const policy = resolveExecutionMemoryPolicy(execution);
  if (policy.mode === 'missing' || policy.mode === 'none') {
    execution.memory_context = {
      status: policy.mode === 'none' ? 'not_applicable' : 'missing',
      blocking: false,
      memory_contract: null,
      memory_read_receipt: null,
    };
    return;
  }

  const stagePacket = execution.stage_context_packet && typeof execution.stage_context_packet === 'object'
    ? execution.stage_context_packet
    : null;
  if (policy.context_source === 'stage_context'
      && stagePacket
      && stagePacket.memory_contract
      && stagePacket.memory_read_receipt) {
    execution.memory_context = {
      status: 'assembled',
      blocking: false,
      context_source: 'stage_context',
      packet_md: String(stagePacket.packet_md || ''),
      packet_json: String(stagePacket.packet_json || ''),
      estimated_tokens: Number(stagePacket.estimated_tokens || 0),
      memory_contract: stagePacket.memory_contract,
      memory_read_receipt: stagePacket.memory_read_receipt,
    };
    return;
  }
  if (policy.context_source === 'stage_context') {
    execution.memory_context = {
      status: 'stage_context_not_assembled',
      blocking: false,
      context_source: 'stage_context',
      packet_md: '',
      packet_json: '',
      estimated_tokens: 0,
      memory_contract: null,
      memory_read_receipt: null,
    };
    if (!execution.context_packet_warning) {
      execution.context_packet_warning = '当前阶段上下文尚未生成；不得回退读取旧的全局记忆。';
    }
    return;
  }

  const runId = `interactive-${String(task.workflow_id || 'workflow')}-${String(targetStage || 'stage')}-${String(execution.stage_attempt_id || Date.now())}`;
  const context = prepareMemoryContext(root, task, execution, policy, runId);
  execution.memory_context = context;
  if (context.blocking) {
    execution.context_packet_warning = `记忆上下文不可用：${String(context.status || 'blocked_memory_context')}`;
    return;
  }
  if (!context.memory_read_receipt) return;
  if (!execution.context_read_command) {
    execution.context_read_command = `node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${JSON.stringify(String(task.workflow_id || ''))}`;
  }
  if (!execution.stage_context_packet) {
    execution.stage_context_packet = {
      status: context.status,
      packet_md: context.packet_md,
      packet_json: context.packet_json,
      estimated_tokens: context.estimated_tokens,
      token_budget: context.token_budget,
      source_files: [],
      memory_contract: context.memory_contract,
      memory_read_receipt: context.memory_read_receipt,
    };
  }
}

function attachLongStageExecutionGuidance(root, task, targetStage) {
  if (String(task.workflow_type || '') !== 'long_write') return;
  const execution = task.stage_execution || {};
  execution.execution_workdir = '.';
  delete execution.context_read_command;
  let packet;
  try {
    packet = buildLongStageContextPacket({ projectRoot: root, task, stage: targetStage });
  } catch (error) {
    execution.context_packet_warning = String((error && error.message) || error || 'long context packet failed').slice(0, 240);
    return;
  }
  if (!packet || packet.status !== 'assembled') return;
  execution.context_read_command = `node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${JSON.stringify(String(task.workflow_id || ''))}`;
  execution.stage_context_packet = {
    status: packet.status, packet_md: packet.packet_md, packet_json: packet.packet_json,
    chapter: packet.chapter, volume: packet.volume, estimated_tokens: packet.estimated_tokens,
    token_budget: packet.token_budget, source_files: packet.source_files, draft: packet.draft,
  };
  if (targetStage === 'prose_acceptance') {
    execution.execution_command = `node scripts/long-chapter-machine-gate.js --project-root . --workflow-id ${JSON.stringify(String(task.workflow_id || ''))} --json`;
    execution.quality_command = `node scripts/long-chapter-quality-gate.js --project-root . --workflow-id ${JSON.stringify(String(task.workflow_id || ''))} --apply --json`;
    execution.resume_hint = '先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径。再运行 execution_command；通过后完成八项故事判断并运行 quality_command。质量脚本会返回 pass/revise 两条单命令，按判断选择其一执行；不得把占位符交给 shell，不得逐个调用检查器或扩读全书。';
  } else if (targetStage === 'prose') {
    execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；据此写当前第${packet.chapter}章候选稿，不得读取完整总纲、卷纲、细纲、任务日志或无关章节。`;
  } else {
    execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；据此完成当前第${packet.chapter}章阶段，仅在包内 gate.fail 指明缺口时读取对应 sourceFiles。`;
  }
}

function shortPlanningWorkspacePath(task, targetStage, attempt, canonical) {
  const workspaceId = crypto.createHash('sha256')
    .update(`${String(task.workflow_id || '')}\0${String(targetStage || '')}\0${String(attempt || '')}`)
    .digest('hex')
    .slice(0, 12);
  return `追踪/workflow/staging/${workspaceId}/${path.basename(canonical)}`;
}

function chooseShortPlanningStagedPath(root, task, execution, targetStage, attempt, canonical, existingPath = '') {
  const existing = String(existingPath || '').replace(/\\/g, '/').replace(/^\.\//, '');
  const existingFile = existing ? path.join(root, existing) : '';
  const formalFile = path.join(root, canonical);
  if (existingFile && fs.existsSync(existingFile) && fs.statSync(existingFile).isFile()) {
    if (!fs.existsSync(formalFile) || !fs.statSync(formalFile).isFile()) return existing;
    if (hashFile(existingFile) !== hashFile(formalFile)) return existing;
  }
  return shortPlanningWorkspacePath(task, targetStage, attempt, canonical);
}

function seedShortPlanningStagedFile(root, staged, canonical) {
  const stagedFile = path.join(root, staged);
  if (fs.existsSync(stagedFile) && fs.statSync(stagedFile).isFile()) return;
  const formalFile = path.join(root, canonical);
  atomicWriteText(stagedFile, fs.existsSync(formalFile) && fs.statSync(formalFile).isFile() ? fs.readFileSync(formalFile, 'utf8') : '');
}

function attachShortStageExecutionGuidance(root, task, targetStage) {
  if (!['short_write', 'short_startup', 'private_short_startup'].includes(String(task.workflow_type || ''))) return;
  const execution = task.stage_execution || {};
  execution.execution_workdir = '.';
  const quotedRoot = '.';
  const quotedWorkflowId = JSON.stringify(String(task.workflow_id || ''));
  delete execution.context_read_command;
  const wholeStoryStage = ['section_plan_lock', 'short_structure_impact_audit', 'hook_retention_gate', 'hook_value_gate', 'full_story_assembly', 'full_story_review', 'short_deslop', 'deslop', 'final_check'].includes(targetStage);
  const wholeStoryFeedback = ['feedback_impact_sync', 'feedback_apply_patch'].includes(targetStage)
    && /(?:全篇|整篇|全文|通篇)/u.test(String((((task || {}).pending_feedback || {}).scope_snapshot) || task.scope || ''));
  if (wholeStoryStage || wholeStoryFeedback) synchronizeShortWholeStoryScope(task, targetStage);

  if (targetStage === 'feedback_apply_patch') {
    const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
    const plannedAssets = Array.isArray(((acceptedPlan.projection_plan || {}).planning_assets))
      ? acceptedPlan.projection_plan.planning_assets
        .map(item => String(item || '').replace(/\\/g, '/').replace(/^\.\//, ''))
        .filter(item => /^(?:素材卡|设定|小节大纲)\.md$/u.test(item))
      : [];
    if (!String(acceptedPlan.plan_id || '') || plannedAssets.length === 0) {
      execution.context_packet_warning = '已确认方案缺少规划资产写集，不能启动反馈回写。';
      execution.resume_hint = '返回反馈影响分析阶段补齐方案、受影响规划资产和小节范围；不得直接修改正式文件。';
      return;
    }
    const attempt = String(execution.stage_attempt_id || 'attempt').replace(/[^A-Za-z0-9._-]/g, '_');
    const existingTargets = new Map((Array.isArray(execution.planning_targets) ? execution.planning_targets : [])
      .map(item => [String((item || {}).canonical || ''), String((item || {}).staged || '')]));
    execution.planning_targets = plannedAssets.map(canonical => {
      const staged = chooseShortPlanningStagedPath(root, task, execution, targetStage, attempt, canonical, existingTargets.get(canonical));
      seedShortPlanningStagedFile(root, staged, canonical);
      return { canonical, staged };
    });
    execution.write_set = execution.planning_targets.map(item => item.staged);
    execution.planning_inputs = [task.accepted_plan_path, '素材卡.md', '设定.md', '小节大纲.md']
      .filter((item, index, values) => item && values.indexOf(item) === index && fs.existsSync(path.join(root, item)));
    execution.execution_command = `node scripts/short-planning-stage-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
  }

  const planningTarget = shortPlanningCanonicalTarget(targetStage);
  if (planningTarget) {
    const attempt = String(execution.stage_attempt_id || 'attempt').replace(/[^A-Za-z0-9._-]/g, '_');
    const stagedTarget = chooseShortPlanningStagedPath(root, task, execution, targetStage, attempt, planningTarget, execution.planning_target);
    seedShortPlanningStagedFile(root, stagedTarget, planningTarget);
    execution.write_set = [stagedTarget];
    execution.planning_target = stagedTarget;
    execution.planning_canonical_target = planningTarget;
    execution.planning_inputs = shortPlanningInputs(targetStage).filter((file) => fs.existsSync(path.join(root, file)));
    execution.execution_command = `node scripts/short-planning-stage-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    const inputs = execution.planning_inputs.length ? execution.planning_inputs.join('、') : '当前已确认的用户输入与工作流上下文';
    execution.resume_hint = `只读取 ${inputs}，只修改暂存制品 ${stagedTarget}；完成后运行 execution_command 受控提交到 ${planningTarget}。不得直接写正式文件、手写 result packet 或读取 workflow 源码。`;
    return;
  }

  if (targetStage === 'section_plan_lock') {
    execution.write_set = ['追踪/private-short-extension/section-title-lock.json', '追踪/private-short-extension/project-state.json'];
    execution.execution_command = `node scripts/short-section-title-lock.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --json`;
    execution.resume_hint = '直接运行 execution_command。已确认且与当前小节大纲一致的标题锁会被复用并完成本阶段；标题发生变化时会显示完整标题清单和 1/2/3/4 选择。不得读取上下文包、手写结果包或重复扫描项目。';
    return;
  }

  if (targetStage === 'short_structure_impact_audit') {
    execution.write_set = [`${task.task_dir}/artifacts/short-structure-impact-audit.json`];
    execution.execution_command = `node scripts/short-structure-impact-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '直接运行 execution_command。脚本会把规划、Brief、采用锚点、候选稿和合稿逐项标记为保留、失效、重算或复检，并为每个失效项分配恢复阶段；不得人工拼结果包。';
    return;
  }

  if (targetStage === 'hook_retention_gate' || targetStage === 'hook_value_gate') {
    execution.write_set = [`${task.task_dir}/artifacts/${targetStage}/review-card.json`];
    execution.execution_command = `node scripts/short-hook-value-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '先运行 execution_command 生成紧凑证据包；只按返回的审阅卡合同判断标题承诺、开头压力、剧情爆点、黄金阅读、节尾断点、流失风险、主角能动性和因果链，再重跑同一命令。不得修改正文或自由扩读项目。';
    return;
  }

  if (['first_section_brief', 'section_brief', 'next_section_brief'].includes(targetStage)) {
    reconcileShortRevisionQueueWithTitleLock(root, task);
    const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
    const sectionIndex = inferShortSectionIndex({ projectState, stageId: targetStage, scope: String(task.scope || '') }) || 1;
    synchronizeShortUnitScope(task, sectionIndex, targetStage);
    const lock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
    const titleEntry = (Array.isArray(lock.sections) ? lock.sections : []).find((item) => Number((item || {}).section_index) === sectionIndex);
    if (!titleEntry || titleEntry.confirmed !== true) {
      execution.title_confirmation_required = true;
      execution.section_index = sectionIndex;
      execution.execution_command = `node scripts/short-section-title-lock.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --json`;
      execution.resume_hint = `第${sectionIndex}节标题尚未确认。只运行 execution_command 展示全篇小节标题，等待用户确认或修改大纲；不得生成 Brief。`;
      return;
    }
  }

  if (targetStage === 'section_machine_gate') {
    execution.execution_command = `node scripts/short-section-machine-gate.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '直接运行 execution_command。不要逐个调用检查器，不要读取平台源码，不要手写 result packet。';
    return;
  }
  if (targetStage === 'quality_gate' || targetStage === 'story_value_gate') {
    execution.execution_command = `node scripts/short-section-quality-gate.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
  }
  if (targetStage === 'section_accept_anchor') {
    execution.execution_command = `node scripts/short-section-accept-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '直接运行 execution_command；脚本会从已通过的 Brief、正文和质量回执生成采用锚点。不得重新审查、统计字数、手写元数据或读取平台源码。';
    return;
  }
  if (targetStage === 'full_story_assembly') {
    synchronizeShortWholeStoryScope(task, targetStage);
    task.recommended_next = [{
      number: 1,
      action_id: 'run_current_stage',
      label: '组装已采用的全部小节（推荐）',
      description: '按锁定顺序合并已采用小节；不会生成计划外的新小节。',
    }];
    execution.execution_command = `node scripts/short-story-assembly-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '直接运行 execution_command。脚本只按已采用的小节顺序合稿；缺节、失效锚点或计划外小节会停住，不得手工拼接或生成新小节。';
    return;
  }
  if (targetStage === 'full_story_review') {
    synchronizeShortWholeStoryScope(task, targetStage);
    execution.write_set = [`${task.task_dir}/artifacts/full-story-review/**`];
    execution.execution_command = `node scripts/short-story-review-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '先运行 execution_command 生成确定性证据包。若返回 short_story_editorial_review_required，优先并行调用 story-architect 与 character-designer；Agent 不可用时由 story-review 按同一合同 solo fallback。按返回 schema 只写一张综合审阅卡，再重跑同一命令；不得修改正文、重读 workflow 源码或自造下一阶段。';
    return;
  }
  if (targetStage === 'short_deslop' || targetStage === 'deslop' || targetStage === 'final_check') {
    synchronizeShortWholeStoryScope(task, targetStage);
  }
  if (targetStage === 'short_deslop' || targetStage === 'deslop') {
    const attempt = String(execution.stage_attempt_id || 'attempt').replace(/[^A-Za-z0-9._-]/g, '_');
    const sourceFile = path.join(root, '正文.md');
    if (!fs.existsSync(sourceFile) || !fs.statSync(sourceFile).isFile()) {
      execution.context_packet_warning = '正式合并稿 正文.md 缺失，不能启动短篇去 AI 味。';
      execution.resume_hint = '返回全篇组装阶段恢复 正文.md；不要手写结果包。';
      return;
    }
    const stagedTarget = `${task.task_dir}/artifacts/short-deslop/${attempt}/正文.md`;
    atomicWriteText(path.join(root, stagedTarget), fs.readFileSync(sourceFile, 'utf8'));
    execution.write_set = [stagedTarget];
    execution.deslop_target = stagedTarget;
    execution.deslop_source_digest = hashFile(sourceFile);
    execution.execution_command = `node scripts/short-story-deslop-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = `只读取并修改 ${stagedTarget}，按短篇规则做表达层清理，不改人物、因果、钩子、节序和标题。完成后只运行 execution_command；不得直接写 正文.md、调用小节修订脚本、搜索 workflow 源码或手写 result packet。`;
    return;
  }
  if (targetStage === 'final_check') {
    execution.write_set = [];
    execution.execution_command = `node scripts/short-story-final-check.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
    execution.resume_hint = '直接运行 execution_command 完成节数守恒、正式稿哈希、污染与发布完整性检查。不得重新阅读全文、手写回执或生成计划外小节。';
    return;
  }
  if (targetStage === 'section_repair_loop') {
    const deterministic = resolveDeterministicShortRepair(root, task);
    if (deterministic.status === 'quote_only') {
      execution.write_set = [deterministic.repair_target];
      execution.repair_target = deterministic.repair_target;
      execution.repair_input_digest = hashFile(deterministic.repair_file);
      execution.deterministic_repair = 'mainland_quote_normalization';
      execution.execution_command = `node scripts/short-section-repair-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --normalize-quotes --apply --json`;
      execution.resume_hint = `当前机器门只发现引号样式问题。直接运行 execution_command 确定性转换 ${deterministic.repair_target} 并自动复检；不要读取正文、上下文包或脚本源码，不要重写句子。`;
      return;
    }
  }

  try {
    const packet = buildStageContextPacket({ projectRoot: root, task, stage: targetStage });
    if (packet.status !== 'assembled') {
      const required = Array.isArray(packet.required_context)
        ? packet.required_context.map(item => `${String((item || {}).id || '必需资产')}(${String((item || {}).reason || '不可用')})`).join('、')
        : '';
      execution.context_packet_warning = required
        ? `当前阶段上下文未就绪：${required}`
        : `当前阶段上下文未就绪：${String(packet.status || packet.reason || 'unknown')}`;
      execution.stage_context_failure = packet;
      return;
    }
    execution.context_read_command = `node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${quotedWorkflowId}`;
    if (!wholeStoryFeedback) synchronizeShortUnitScope(task, packet.section_index, targetStage);
    execution.stage_context_packet = {
      status: packet.status,
      packet_md: packet.packet_md,
      packet_json: packet.packet_json,
      section_index: packet.section_index,
      estimated_tokens: packet.estimated_tokens,
      token_budget: packet.token_budget,
      source_files: packet.source_files,
      memory_contract: packet.memory_contract || null,
      memory_read_receipt: packet.memory_read_receipt || null,
    };
    if (['draft_first_section', 'draft_section', 'draft_next_section'].includes(targetStage)) {
      const draftTarget = `草稿_第${String(packet.section_index).padStart(3, '0')}节_候选.md`;
      const draftFile = path.join(root, draftTarget);
      execution.write_set = [draftTarget];
      execution.draft_target = draftTarget;
      execution.draft_input_digest = fs.existsSync(draftFile) ? hashFile(draftFile) : '';
      execution.execution_command = `node scripts/short-section-draft-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
      execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；只写 ${draftTarget}。完成后运行 execution_command；不得手写 result packet、连续写下一节、重复扫描项目或猜状态机参数。`;
    } else if (targetStage === 'section_repair_loop') {
      const draftSource = (packet.source_files || []).find((source) => String((source || {}).kind || '') === 'current_draft');
      const repairTarget = String((draftSource || {}).path || '');
      const repairFile = repairTarget ? path.join(root, repairTarget) : '';
      if (!repairTarget || !repairFile || !fs.existsSync(repairFile)) {
        execution.context_packet_warning = '当前小节候选稿缺失，不能启动修订阶段。';
        return;
      }
      execution.write_set = [repairTarget];
      execution.repair_target = repairTarget;
      execution.repair_input_digest = hashFile(repairFile);
      execution.execution_command = `node scripts/short-section-repair-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
      execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；只修改 ${repairTarget}。完成后运行 execution_command；不得直接运行机器门、猜状态机参数、读取脚本源码或扫描其他文件。`;
    } else if (targetStage === 'quality_gate' || targetStage === 'story_value_gate') {
      const evidenceRel = `${task.task_dir}/artifacts/section-${String(packet.section_index).padStart(3, '0')}-story-review.json`;
      const draftSource = (packet.source_files || []).find((source) => String((source || {}).kind || '') === 'current_draft');
      const draftRel = String((draftSource || {}).path || '');
      const draftFile = draftRel ? path.join(root, draftRel) : '';
      const outlineContract = buildShortSectionOutlineContract(root, packet.section_index);
      atomicWriteJson(path.join(root, evidenceRel), {
        schemaVersion: '1.0.0',
        workflow_id: String(task.workflow_id || ''),
        section_index: packet.section_index,
        draft: draftRel,
        draft_digest: draftFile && fs.existsSync(draftFile) ? hashFile(draftFile) : '',
        outline_contract_digest: outlineContract.status === 'current' ? outlineContract.contract_digest : '',
        outline_coverage: outlineContract.status === 'current'
          ? outlineContract.obligations.filter((item) => item.required_in_draft).map((item) => ({ id: item.id, status: '', evidence_quote: '' }))
          : [],
        checks: ['role_lock', 'causal_chain', 'title_promise', 'protagonist_agency', 'human_emotion', 'hook_payoff', 'story_attraction', 'continuity', 'drift_control', 'outline_fidelity', 'section_function_completion']
          .map((id) => ({ id, status: '', evidence: '', evidence_quote: '' })),
        summary: '',
        acceptance_metadata: {
          revealed_information: [],
          present_characters: [],
          character_state: {},
          relationship_state: {},
          knowledge_state: {},
          world_state: {},
          decisions: [],
          causal_links: [],
          promise_deltas: [],
          protagonist: '',
          open_hook: '',
          carry_forward: [],
        },
      });
      execution.quality_evidence_target = evidenceRel;
      execution.write_set = [evidenceRel];
      execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；把十一项故事质量判断写入 ${evidenceRel}：每项填写 pass/revise、判断理由和正文原句 evidence_quote；再逐项填写大纲覆盖与承接元数据，运行 execution_command。不要修改正文、搜索实现、协议或历史回执。`;
    } else if (['first_section_brief', 'section_brief', 'next_section_brief'].includes(targetStage)) {
      execution.execution_command = `node scripts/short-section-brief-finalize.js --project-root ${quotedRoot} --workflow-id ${quotedWorkflowId} --apply --json`;
      execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；生成第${packet.section_index}节写作提要：只保留承接、目标与阻力、因果动作、人物/视角锁、禁写项、节尾钩子六部分，同一事实只写一次，篇幅和事件数按目标正文动态收敛。随后运行 execution_command；不得读取完整 skill 或历史回执。`;
    } else if (targetStage === 'feedback_impact_sync') {
      execution.resume_hint = '先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；按反馈批次逐项输出影响层级、受影响规划文件、小节范围、保留项、失效 Brief/正文和回写顺序。本阶段不改创作资产，不得遗漏前序意见或复用旧反馈结论。';
    } else if (targetStage === 'feedback_apply_patch') {
      const staged = (execution.planning_targets || []).map(item => item.staged).join('、');
      execution.resume_hint = `先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；只修改暂存规划资产 ${staged}。按已确认方案回写后运行 execution_command，一次性提交规划资产、建立受影响小节修订队列并使旧 Brief/正文进入待复检。不得直接覆盖正式规划文件或正文。`;
    } else {
      execution.resume_hint = '先逐字运行 context_read_command 读取当前最小包，不得手抄 packet_md 路径；据此完成当前小节，不得加载完整 skill、协议、任务日志、历史回执或平台源码。';
    }
  } catch (error) {
    execution.context_packet_warning = String((error && error.message) || error || 'stage context packet failed').slice(0, 240);
  }
}

function shortPlanningCanonicalTarget(stageId) {
  return ({
    project_seed: '素材卡.md',
    material_card: '素材卡.md',
    short_setting: '设定.md',
    platform_genre_lock: '设定.md',
    rhythm_pattern_selection: '设定.md',
    section_outline: '小节大纲.md',
  })[String(stageId || '')] || '';
}

function shortPlanningInputs(stageId) {
  const map = {
    project_seed: [],
    material_card: [],
    short_setting: ['素材卡.md'],
    platform_genre_lock: ['素材卡.md', '设定.md'],
    rhythm_pattern_selection: ['素材卡.md', '设定.md'],
    section_outline: ['素材卡.md', '设定.md'],
  };
  return map[String(stageId || '')] || [];
}

function synchronizeShortUnitScope(task, sectionIndex, stageId) {
  const normalizedIndex = Number(sectionIndex || 0);
  if (!Number.isInteger(normalizedIndex) || normalizedIndex < 1) return;
  const scope = `第${normalizedIndex}节`;
  task.scope = scope;
  task.unit_lifecycle = {
    ...(task.unit_lifecycle || {}),
    unit_type: 'section',
    status: 'active',
    current_scope: scope,
    current_stage: String(stageId || task.current_stage || ''),
    updated_at: new Date().toISOString(),
  };
}

function synchronizeShortWholeStoryScope(task, stageId) {
  task.scope = '全篇';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.scope = '全篇';
  task.lifecycle.updated_at = new Date().toISOString();
  task.unit_lifecycle = {
    ...(task.unit_lifecycle || {}),
    unit_type: 'story',
    status: 'active',
    current_scope: '全篇',
    current_stage: String(stageId || task.current_stage || ''),
    updated_at: new Date().toISOString(),
  };
}

function resolveDeterministicShortRepair(root, task) {
  const packetRel = String(((task.machine || {}).last_result_packet) || '');
  const packet = readJson(packetRel ? path.join(root, packetRel) : '') || {};
  const blocking = Array.isArray(packet.blocking_findings) ? packet.blocking_findings : [];
  if (!['blocking', 'blocked'].includes(String(packet.machine_gate_result || packet.verification_result || '')) || blocking.length === 0) {
    return { status: 'not_applicable' };
  }
  const quoteOnly = blocking.every((item) => /(?:ascii-quote-style|quote-style|引号|quote)/iu.test(`${String((item || {}).code || '')} ${String((item || {}).message || '')}`));
  if (!quoteOnly) return { status: 'not_applicable' };
  const outputs = Array.isArray(packet.outputs) ? packet.outputs.map(String) : [];
  const repairTarget = outputs.find((item) => /(?:草稿_第\d+节_候选|正文_第\d+节)\.md$/u.test(item)) || '';
  const repairFile = repairTarget ? path.resolve(root, repairTarget) : '';
  if (!repairTarget || !repairFile.startsWith(`${root}${path.sep}`) || !fs.existsSync(repairFile) || !fs.statSync(repairFile).isFile()) {
    return { status: 'not_applicable' };
  }
  return { status: 'quote_only', repair_target: repairTarget, repair_file: repairFile };
}

function createStageAttemptId(workflowId, stageId) {
  return `sa-${String(workflowId || 'workflow')}-${String(stageId || 'stage')}-${crypto.randomBytes(4).toString('hex')}`;
}

function expectedResultPacketPath(task, stageId, projectRoot = '') {
  const baseDir = task.context_paths && task.context_paths.result_packets_dir
    ? task.context_paths.result_packets_dir
    : `${task.task_dir || `追踪/workflow/tasks/${task.workflow_id || 'unknown-workflow'}`}/result-packets`;
  const shortUnitStages = new Set([
    'first_section_brief', 'section_brief', 'next_section_brief',
    'draft_first_section', 'draft_section', 'draft_next_section',
    'section_machine_gate', 'section_repair_loop', 'quality_gate',
    'story_value_gate', 'section_candidate_compare', 'section_accept_anchor',
    'feedback_impact_sync', 'feedback_apply_patch',
  ]);
  const wholeStoryScope = /(?:全篇|整篇|全文|通篇)/.test(`${String(task.scope || '')} ${String((((task || {}).pending_feedback || {}).scope_snapshot) || '')}`);
  if (['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || '')) && isShortWritingWorkflow(task)) {
    const feedbackId = String((((task || {}).pending_feedback || {}).feedback_id) || 'feedback-unbound')
      .replace(/[^A-Za-z0-9._-]/g, '_');
    return `${baseDir}/${stageId}.${feedbackId}.result.json`;
  }
  if (shortUnitStages.has(String(stageId || '')) && isShortWritingWorkflow(task) && !wholeStoryScope) {
    const root = projectRoot ? path.resolve(projectRoot) : '';
    const projectState = root ? (readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {}) : {};
    const sectionIndex = inferShortSectionIndex({ projectState, stageId, scope: String(task.scope || '') });
    if (Number.isInteger(sectionIndex) && sectionIndex > 0) {
      return `${baseDir}/${stageId}.section-${String(sectionIndex).padStart(3, '0')}.result.json`;
    }
  }
  return `${baseDir}/${stageId}.result.json`;
}

function buildConfirmationContext(task, selected, stageId, selectedAt) {
  return {
    status: 'confirmed',
    workflow_id: task.workflow_id || '',
    workflow_type: task.workflow_type || '',
    stage_id: stageId,
    step_id: stageId,
    selection_id: selected.selection_id || '',
    selected_number: selected.selected_number,
    selected_action_id: selected.action_id || '',
    selected_at: selectedAt,
    confirmed_at: selectedAt,
    expires_at: selected.selection_expires_at || '',
    visible_choice_hash: selected.visible_choice_hash || '',
    confirmation_token: crypto.randomBytes(24).toString('hex'),
    operation: task.workflow_type === 'cover' ? (task.cover_operation || 'generate') : '',
    target_scope: selected.target_scope || task.scope || '',
    target_files: Array.isArray(selected.target_files) ? selected.target_files.slice() : [],
  };
}

function inferCoverOperation(userGoal, scope) {
  return /覆盖|替换|overwrite/i.test(`${userGoal || ''} ${scope || ''}`) ? 'overwrite' : 'generate';
}

function classifyFreeTextInput(task, input, pending) {
  const text = String(input || '').trim();
  const freeTextEnabled = pending.free_text_enabled !== false;
  if (!freeTextEnabled) {
    return blocked('blocked_free_text_disabled', '当前候选不接受自由输入，请选择已有数字候选或重新开启任务。');
  }
  let classification = inferFreeTextClassification(text);
  if (isShortWritingWorkflow(task)
    && ['feedback_impact_sync', 'feedback_apply_patch'].includes(String(task.current_stage || ''))
    && classification.classification === 'free_text_instruction') {
    classification = {
      classification: 'current_artifact_feedback',
      recommended_action: 'route_feedback_before_execution',
      suggested_workflow_type: '',
      target_scope: '',
      reason: '当前处于短篇反馈处理阶段；普通自然语言按当前方案的补充反馈处理，并重新计算影响链。',
    };
  }
  const replanActions = classification.classification === 'scope_change'
    ? buildReplanActions({
      feedback: text,
      change_type: inferStructureChangeType(text),
    })
    : {};
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'free_text_classified',
    input: text,
    classification: classification.classification,
    recommended_action: classification.recommended_action,
    suggested_workflow_type: classification.suggested_workflow_type,
    target_scope: classification.target_scope,
    reason: classification.reason,
    ...replanActions,
    current_workflow_id: task.workflow_id || '',
    current_workflow_type: task.workflow_type || '',
    current_task_status: task.status || '',
    free_text_enabled: true,
    must_not_bind_to_pending_number: true,
    runner_contract: {
      do_not_execute_pending_number: true,
      route_feedback_before_execution: classification.recommended_action === 'route_feedback_before_execution',
      call_switch_intent: classification.recommended_action === 'call_switch_intent',
      keep_current_task_resumable: true,
    },
  };
}

function inferStructureChangeType(text) {
  if (/插入|插章/.test(text)) return 'insert';
  if (/合并/.test(text)) return 'merge';
  if (/删除|删章/.test(text)) return 'delete';
  if (/扩容/.test(text)) return 'expand';
  if (/缩容/.test(text)) return 'shrink';
  if (/前移|后移/.test(text)) return 'move';
  if (/重排/.test(text)) return 'reorder';
  return '';
}

function applyLongformStructureFeedback(task, replan, input) {
  const tpl = templates().long_write;
  const graph = normalizeLongformLifecycleGraph(task, tpl);
  const changedId = replan.return_to;
  const assets = graph.nodes.map((node, index) => ({
    id: node.id,
    kind: node.id,
    status: node.status,
    depends_on: index > 0 ? [graph.nodes[index - 1].id] : [],
  }));
  const downstream = invalidateDownstream({ assets }, { id: changedId, kind: replan.impact_level });
  const updateById = new Map(downstream.metadata_updates.map(update => [update.id, update]));
  const affectedPlanning = new Set([...downstream.needs_recheck, ...downstream.invalidated]);
  const now = new Date().toISOString();
  const stageDef = findStage(tpl, changedId);

  graph.current_node = changedId;
  graph.asset_target = { ...stageDef.asset_target };
  graph.completed_nodes = graph.completed_nodes.filter(id => id !== changedId && !affectedPlanning.has(id));
  graph.invalidated_nodes = Array.from(new Set([
    ...graph.invalidated_nodes.filter(id => id !== changedId),
    ...downstream.invalidated,
  ]));
  graph.nodes = graph.nodes.map(node => {
    if (node.id === changedId) return { ...node, status: 'needs_recheck' };
    const update = updateById.get(node.id);
    if (!update || update.status === 'preserve_until_proven_invalid') return node;
    return { ...node, status: update.status };
  });
  for (const id of affectedPlanning) delete graph.review_results[id];

  const downstreamEffects = { ...replan.downstream_effects, ...downstream };
  const impactMetadata = {
    feedback: String(input || ''),
    impact_level: replan.impact_level,
    change_type: replan.change_type,
    analyzed_at: now,
    downstream_effects: downstreamEffects,
  };
  const replanMetadata = {
    return_to: changedId,
    replanned_at: now,
    actions: replan.actions.slice(),
    preserve_chapter_names: replan.preserve_chapter_names,
    preserve_reusable_content: replan.preserve_reusable_content,
  };
  graph.last_impact_analysis = impactMetadata;
  graph.last_replan = replanMetadata;
  task.lifecycle_graph = graph;
  task.lifecycle_impact = impactMetadata;
  task.replan_metadata = replanMetadata;
  task.current_stage = changedId;
  task.current_step = changedId;
  task.machine.completed_stages = task.machine.completed_stages.filter(id => id !== changedId && !affectedPlanning.has(id));
  task.machine.remaining_stages = tpl.stages.map(item => item.stage_id).slice(tpl.stages.findIndex(item => item.stage_id === changedId));
  task.machine.last_transition = 'structure_feedback_replan';
  task.machine.next_stop_reason = nextStopReason(task, stageDef);
  task.pending_action = buildPendingAction(tpl, stageDef);
  task.unit_lifecycle = {
    ...task.unit_lifecycle,
    status: 'active',
    current_stage: changedId,
    current_role: currentUnitRole(tpl.unit_lifecycle_contract, changedId),
    updated_at: now,
  };
  if (task.stage_execution && task.stage_execution.status === 'running') {
    task.stage_execution = {
      ...task.stage_execution,
      status: 'paused',
      stopped_at: now,
      stop_reason: 'structure_feedback_replan',
    };
  }
}

function inferFreeTextClassification(text) {
  const normalized = text.replace(/\s+/g, ' ');
  const scopeMatch = normalized.match(/(\d+\s*[-到至]\s*\d+)/);
  const targetScope = scopeMatch ? scopeMatch[1].replace(/\s+/g, '') : '';
  if (/先别|不要继续|换个任务|新任务|改成|转去|先审|审阅|审查/.test(normalized) && /(审阅|审查|拆文|写|短篇|长篇|去\s*AI|下载|导入)/.test(normalized)) {
    return {
      classification: 'switch_intent',
      recommended_action: 'call_switch_intent',
      suggested_workflow_type: suggestedWorkflowType(normalized),
      target_scope: targetScope,
      reason: '用户输入包含明显的新任务或切换意图；不得绑定到旧数字候选。',
    };
  }
  if (isStructuralScopeChange(normalized)) {
    return {
      classification: 'scope_change',
      recommended_action: 'route_upstream_replan',
      suggested_workflow_type: 'long_write',
      target_scope: targetScope,
      reason: '用户改变章/节数量、边界或顺序；需要先回到计划锁定和影响审计。',
    };
  }
  if (/不合理|不对|跑题|人物|动机|逻辑|重做|重写|回炉|反馈|修改|更新|调整|改一下|改为|改成|换成|替换|删除|删掉|不像人|不好看|没爽点|太平|太AI|AI味/.test(normalized)
    || /第\s*\d+\s*节[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(normalized)
    || /(?:开头|结尾|这一节)[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(normalized)) {
    return {
      classification: 'current_artifact_feedback',
      recommended_action: 'route_feedback_before_execution',
      suggested_workflow_type: '',
      target_scope: targetScope,
      reason: '用户在评价当前产物；先判断是否修当前阶段或回写上游设定/大纲/Brief。',
    };
  }
  return {
    classification: 'free_text_instruction',
    recommended_action: 'route_by_intent_schema',
    suggested_workflow_type: suggestedWorkflowType(normalized),
    target_scope: targetScope,
    reason: '自由输入需要先做结构化意图识别，再决定是否沿用当前任务。',
  };
}

function isStructuralScopeChange(text) {
  if (/扩容|缩容|重排/.test(text)) return true;
  const unit = '(?:第\\s*\\d+\\s*)?(?:卷|章|章节|节|小节)';
  const structuralAction = '(?:插入|插一|增加|新增|拆分|拆成|合并|删除|删掉|前移|后移|移动)';
  return new RegExp(`${structuralAction}[^。；，,]{0,18}${unit}|${unit}[^。；，,]{0,18}${structuralAction}`).test(text);
}

function suggestedWorkflowType(text) {
  if (/封面|封皮|书皮/.test(text)) return 'cover';
  if (/短篇.*(扫榜|排行|什么火)|((扫榜|排行|什么火).*)短篇/.test(text)) return 'short_scan';
  if (/长篇.*(扫榜|排行|什么火)|((扫榜|排行|什么火).*)长篇|起点|番茄|晋江/.test(text)) return 'long_scan';
  if (/短篇.*(拆文|拆书|拆解|分析)|((拆文|拆书|拆解|分析).*)短篇/.test(text)) return 'short_analyze';
  if (/审阅|审查|复检/.test(text)) return 'review_repair';
  if (/拆文|拆书|拆解|学习/.test(text)) return 'long_analyze';
  if (/短篇|小节|脑洞|素材卡/.test(text)) return 'short_write';
  if (/去\s*AI|AI味|润色|精修/.test(text)) return 'deslop';
  if (/下载|导入|续更/.test(text)) return 'download_import';
  if (/长篇|章节|卷纲|细纲|正文|扩容|缩容/.test(text)) return 'long_write';
  return '';
}

function nextCandidates(args) {
  const root = path.resolve(args.projectRoot);
  const task = readFocusedAuthority(root);
  if (!task) return { schemaVersion: SCHEMA_VERSION, status: 'no_active_task', next_candidates: [] };
  if (task.__error) return blockedFocusedAuthority(task);
  const lifecycleMigration = longformLifecycleMigrationBlock(task);
  if (lifecycleMigration) return lifecycleMigration;
  const lifecycleProgress = longformLifecycleProgressBlock(task);
  if (lifecycleProgress) return lifecycleProgress;
  const reviewPlanValidation = validateTaskReviewPlan(root, task);
  if (reviewPlanValidation.blocked) return reviewPlanValidation.blocked;
  if (reviewPlanValidation.legacy) return blockedLegacyReviewPlan(task);
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') return blockedTaskTemplate(registryCheck);
  const tpl = registryCheck.template;
  const current = findStage(tpl, task.current_stage);
  const status = shouldStopBeforeStage(task, current) ? 'requires_user_confirm' : 'ok';
  const visibleResponse = pendingActionVisibleResponse(task, root);
  return {
    schemaVersion: SCHEMA_VERSION,
    status,
    target_stage: current ? current.stage_id : '',
    pending_action: refreshedVisibleMenu(task, root),
    next_candidates: visibleResponse.options || [],
    visible_response: visibleResponse,
  };
}

function memoryProjectionDebtPendingAction(task) {
  const attempts = Number((((task || {}).memory_projection_debt || {}).attempt_count) || 1);
  return decoratePendingAction({
    id: `pa-memory-projection-${String((task || {}).workflow_id || 'task')}`,
    question: '本阶段结果已接受，但记忆投影尚未完成',
    options: [
      {
        number: 1,
        action_id: 'replay_memory_projection',
        label: attempts < 3 ? '重放记忆投影（推荐）' : '修复记忆服务后重放投影',
        description: '复用已接受的结果包，只重放记忆投影；不会重新调用模型或重写正文。',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        number: 2,
        action_id: 'inspect_current_state',
        label: '查看投影错误与已接受结果',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        number: 3,
        action_id: 'pause',
        label: '暂停并保存断点',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        number: 4,
        action_id: 'free_text',
        label: '输入其他要求',
        risk_level: 'low',
        requires_user_confirm: false,
      },
    ],
    free_text_enabled: true,
  });
}

function replayAcceptedMemoryProjection(root, task, taskTemplate, reviewPlanValidation) {
  const debt = task.memory_projection_debt && typeof task.memory_projection_debt === 'object'
    ? task.memory_projection_debt
    : null;
  if (!debt || String(debt.status || '') !== 'pending') {
    return blocked('blocked_memory_projection_debt_missing', [{
      field: 'memory_projection_debt',
      message: '当前任务没有可重放的记忆投影债务，请刷新任务状态。',
    }]);
  }
  const resultRel = String(debt.accepted_result_packet || debt.source_result_packet || '');
  const resultFile = resolveSafeProjectFile(root, resultRel);
  const result = resultFile ? readJson(resultFile) : null;
  if (!resultFile || !result || result.__error) {
    return blocked('blocked_memory_projection_result_missing', [{
      field: 'accepted_result_packet',
      message: '已接受结果包缺失，不能重跑模型来替代；请先恢复归档结果包。',
      path: resultRel,
    }]);
  }

  const projection = projectAcceptedMemoryUpdates(root, task, task.stage_execution || {}, result);
  const decision = memoryProjectionAdvanceDecision(((task.stage_execution || {}).memory_contract) || {}, projection);
  if (!decision.can_advance) {
    const now = new Date().toISOString();
    task.memory_projection_debt = {
      ...debt,
      attempt_count: Number(debt.attempt_count || 0) + 1,
      last_attempt_at: now,
      last_error: projection,
    };
    task.pending_action = memoryProjectionDebtPendingAction(task);
    writeTaskState(root, task);
    if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
    appendHistory(root, 'memory_projection_replay_failed', {
      workflow_id: task.workflow_id,
      stage_id: debt.stage_id,
      stage_attempt_id: debt.stage_attempt_id,
      attempt_count: task.memory_projection_debt.attempt_count,
      detail: String(projection.detail || projection.status || ''),
    });
    const visibleResponse = pendingActionVisibleResponse(task, root, '记忆投影重放仍未成功；已接受结果保持不变，也没有重新调用模型。');
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'accepted_pending_projection',
      workflow_id: task.workflow_id,
      memory_projection: projection,
      memory_projection_debt: task.memory_projection_debt,
      retry_without_model: true,
      pending_action: refreshedVisibleMenu(task, root),
      next_candidates: visibleResponse.options || [],
      visible_response: visibleResponse,
      interaction_contract: 'render_visible_response_text_verbatim',
    };
  }

  const now = new Date().toISOString();
  const acceptance = debt.acceptance_context && typeof debt.acceptance_context === 'object'
    ? debt.acceptance_context
    : {};
  task.memory_projection_history = [
    ...(Array.isArray(task.memory_projection_history) ? task.memory_projection_history : []),
    {
      status: 'replayed',
      stage_id: String(debt.stage_id || ''),
      stage_attempt_id: String(debt.stage_attempt_id || ''),
      accepted_result_packet: resultRel,
      attempt_count: Number(debt.attempt_count || 0) + 1,
      projection,
      completed_at: now,
    },
  ].slice(-50);
  task.memory_projection_debt = null;
  task.status = 'running';
  task.lifecycle = { ...(task.lifecycle || {}), status: 'running', updated_at: now };
  task.stage_execution = {
    ...(task.stage_execution || {}),
    status: 'running',
    resumed_at: now,
    stop_reason: '',
  };
  task.pending_action = null;
  appendHistory(root, 'memory_projection_replayed', {
    workflow_id: task.workflow_id,
    stage_id: debt.stage_id,
    stage_attempt_id: debt.stage_attempt_id,
    accepted_result_packet: resultRel,
    attempt_count: Number(debt.attempt_count || 0) + 1,
  });
  return finalizeAcceptedResult({
    root,
    task,
    result,
    resultFile,
    taskTemplate,
    reviewPlanValidation,
    memoryProjection: projection,
    acceptanceContext: {
      canonicalStageReceipt: acceptance.canonical_stage_receipt,
      shortSectionProjection: acceptance.short_section_projection,
      shortAssemblyProjection: acceptance.short_story_assembly_projection,
      shortFullStoryReviewProjection: acceptance.short_full_story_review_projection,
      shortFeedbackIntegration: acceptance.integration_event,
      shortPlanningMemoryProjection: acceptance.planning_memory_projection,
      shortFeedbackRevisionQueue: acceptance.feedback_revision_queue,
      resultHistory: acceptance.result_history,
    },
  });
}

function holdAcceptedResultForMemoryProjection(root, task, result, resultFile, acceptance) {
  const now = new Date().toISOString();
  const previousDebt = task.memory_projection_debt && typeof task.memory_projection_debt === 'object'
    ? task.memory_projection_debt
    : {};
  const archivedPath = String((((acceptance || {}).resultHistory || {}).path) || '');
  task.status = 'accepted_pending_projection';
  task.lifecycle = {
    ...(task.lifecycle || {}),
    status: 'accepted_pending_projection',
    updated_at: now,
  };
  task.stage_execution = {
    ...(task.stage_execution || {}),
    status: 'accepted_pending_projection',
    accepted_at: String((task.stage_execution || {}).accepted_at || now),
    accepted_result_packet: archivedPath || String(result.result_packet_path || rel(root, resultFile)),
    stop_reason: 'memory_projection_pending',
  };
  task.memory_projection_debt = {
    status: 'pending',
    workflow_id: String(task.workflow_id || ''),
    stage_id: String(result.stage_id || (task.stage_execution || {}).stage_id || ''),
    stage_attempt_id: String((task.stage_execution || {}).stage_attempt_id || ''),
    accepted_result_packet: archivedPath || String(result.result_packet_path || rel(root, resultFile)),
    source_result_packet: String(result.result_packet_path || rel(root, resultFile)),
    attempt_count: Number(previousDebt.attempt_count || 0) + 1,
    last_attempt_at: now,
    last_error: (acceptance || {}).memoryProjection || { status: 'projection_failed' },
    retry_without_model: true,
    acceptance_context: {
      canonical_stage_receipt: (acceptance || {}).canonicalStageReceipt || null,
      short_section_projection: (acceptance || {}).shortSectionProjection || null,
      short_story_assembly_projection: (acceptance || {}).shortAssemblyProjection || null,
      short_full_story_review_projection: (acceptance || {}).shortFullStoryReviewProjection || null,
      integration_event: (acceptance || {}).shortFeedbackIntegration || null,
      planning_memory_projection: (acceptance || {}).shortPlanningMemoryProjection || null,
      feedback_revision_queue: (acceptance || {}).shortFeedbackRevisionQueue || null,
      result_history: (acceptance || {}).resultHistory || null,
    },
  };
  task.pending_action = memoryProjectionDebtPendingAction(task);
  writeTaskState(root, task);
  if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
  appendHistory(root, 'memory_projection_debt_created', {
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: task.memory_projection_debt.stage_id,
    stage_attempt_id: task.memory_projection_debt.stage_attempt_id,
    accepted_result_packet: task.memory_projection_debt.accepted_result_packet,
    attempt_count: task.memory_projection_debt.attempt_count,
  });
  const visibleResponse = pendingActionVisibleResponse(task, root, '本阶段业务结果已经接受；记忆尚未投影，因此工作流没有推进。');
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'accepted_pending_projection',
    workflow_id: task.workflow_id,
    current_stage: task.current_stage,
    memory_projection: (acceptance || {}).memoryProjection || null,
    memory_projection_debt: task.memory_projection_debt,
    pending_action: refreshedVisibleMenu(task, root),
    next_candidates: visibleResponse.options || [],
    visible_response: visibleResponse,
    retry_without_model: true,
    interaction_contract: 'render_visible_response_text_verbatim',
  };
}

function applyResult(args) {
  const root = path.resolve(args.projectRoot);
  const resultFile = path.resolve(args.result);
  const result = readJson(resultFile);
  if (!result || result.__error) return blocked('blocked_invalid_result_packet', result ? result.__error : 'missing result packet');
  const resultWorkflowId = String(result.workflow_id || '');
  if (!resultWorkflowId) return blocked('blocked_result_packet_invalid', [{ field: 'workflow_id', message: 'result packet 缺少必填字段。' }]);
  if (args.workflowId && String(args.workflowId) !== resultWorkflowId) {
    return blocked('blocked_result_task_scope_conflict', [{
      field: 'workflow_id',
      message: '显式 workflow_id 与 result packet workflow_id 冲突。',
      expected: String(args.workflowId),
      actual: resultWorkflowId,
    }]);
  }
  const resolved = resolveTaskAuthority(root, resultWorkflowId);
  if (resolved.status !== 'ok') return blocked(resolved.status, resolved.message || 'durable task snapshot is unavailable');
  const task = resolved.task;
  const registryCheck = resolvedTemplateForTask(task);
  if (registryCheck.status !== 'ok') {
    return blockedTaskTemplate(registryCheck);
  }
  const lifecycleMigration = longformLifecycleMigrationBlock(task);
  if (lifecycleMigration) return lifecycleMigration;
  const lifecycleProgress = longformLifecycleProgressBlock(task);
  if (lifecycleProgress) return lifecycleProgress;
  if (task.task_family_id) {
    const family = readTaskFamily(root, task.task_family_id);
    if (family && String(family.head_workflow_id || '') !== String(task.workflow_id || '')) {
      return blocked('blocked_non_head_branch_projection', [{
        field: 'task_family.head_workflow_id',
        message: '当前任务分支已不是该任务族主分支，不能接受结果或投影到写作状态。请切回主分支，或明确创建新的重试/重新规划分支。',
        task_family_id: task.task_family_id,
        head_workflow_id: family.head_workflow_id,
        attempted_workflow_id: task.workflow_id,
      }]);
    }
  }
  const reviewPlanValidation = validateTaskReviewPlan(root, task);
  if (reviewPlanValidation.blocked) return reviewPlanValidation.blocked;
  if (reviewPlanValidation.legacy) return blockedLegacyReviewPlan(task);
  if (Number(task.result_contract_version || 1) >= 2 && !resolveSafeProjectFile(root, resultFile)) {
    return blocked('blocked_result_packet_path_unsafe', 'v2 result packet 必须位于项目目录内。');
  }
  if (!result.result_packet_path) result.result_packet_path = rel(root, resultFile);

  const auditRecovery = recoverTerminalCanonicalAudit(root, task, result, resultFile);
  if (auditRecovery) return auditRecovery;

  const pendingFeedbackBlock = shortFeedbackReconcileBlock(task, result);
  if (pendingFeedbackBlock) return pendingFeedbackBlock;

  const validation = validateResultAgainstTask(task, result, root, resultFile, registryCheck.template);
  if (validation.status !== 'ok') {
    return validation;
  }

  const feedbackImpactValidation = validateShortFeedbackImpactResult(task, result);
  if (feedbackImpactValidation) return feedbackImpactValidation;
  recordShortFeedbackImpactResult(task, result);

  const feedbackPatchValidation = validateShortFeedbackPatchResult(root, task, result, registryCheck.template);
  if (feedbackPatchValidation) return feedbackPatchValidation;

  const shortSectionAcceptanceValidation = validateShortSectionAcceptanceResult(root, task, result);
  if (shortSectionAcceptanceValidation) return shortSectionAcceptanceValidation;

  const shortAssemblyValidation = validateShortStoryAssemblyResult(root, task, result);
  if (shortAssemblyValidation) return shortAssemblyValidation;

  const shortFullStoryReviewValidation = validateShortFullStoryReviewResult(root, task, result);
  if (shortFullStoryReviewValidation) return shortFullStoryReviewValidation;

  const canonicalStageReceipt = acceptValidatedStageWrites(root, task, result, stageCanonicalWriteSet(result));
  if (String(canonicalStageReceipt.status || '').startsWith('blocked_')) {
    return blocked(canonicalStageReceipt.status, [{
      field: 'canonical_stage_receipt',
      message: '长篇阶段写入已经通过写集校验，但无法生成不可变接受回执。',
      details: canonicalStageReceipt,
    }]);
  }

  // Every stage is audited before workflow or memory projection. A direct edit
  // to a formal asset must have an accepted transaction receipt even when the
  // workflow still has many stages left; waiting until terminal completion lets
  // untrusted prose or planning leak into later Briefs and memory packets.
  const stageWriteAudit = auditCanonicalWrites(root, task, {
    // Stage acceptance must only inspect assets this result claims to have
    // changed. The task-wide baseline is retained for terminal closure, but it
    // must not turn an older unrelated edit into a blocker for this stage.
    declaredWriteSet: stageCanonicalWriteSet(result),
  });
  task.canonical_write_audit = stageWriteAudit;
  if (stageWriteAudit.status === 'blocked_unreconciled_canonical_write') {
    blockTerminalCanonicalAudit(task, stageWriteAudit, result, resultFile, 'pre_apply');
    writeTaskState(root, task);
    if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
    appendHistory(root, 'canonical_write_audit_blocked', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: result.stage_id, step_id: result.step_id });
    return {
      schemaVersion: SCHEMA_VERSION,
      status: stageWriteAudit.status,
      unmanaged_paths: stageWriteAudit.unmanaged_paths,
      accepted_paths: stageWriteAudit.accepted_paths,
      audit_file: stageWriteAudit.audit_file || '',
    };
  }

  const shortSectionProjection = projectAcceptedShortSection(root, task, result);
  if (shortSectionProjection && shortSectionProjection.blocked) return shortSectionProjection.blocked;
  const shortAssemblyProjection = projectShortStoryAssembly(root, task, result);
  if (shortAssemblyProjection && shortAssemblyProjection.blocked) return shortAssemblyProjection.blocked;
  const shortFullStoryReviewProjection = projectShortFullStoryReview(root, task, result);
  const shortFeedbackIntegration = recordAcceptedShortFeedback(root, task, result);
  const shortPlanningMemoryProjection = projectAcceptedShortPlanningFeedback(root, task, result);
  if (String(shortPlanningMemoryProjection.status || '').startsWith('blocked_')) {
    return blocked(shortPlanningMemoryProjection.status, [{
      field: 'planning_memory_projection',
      message: shortPlanningMemoryProjection.message || '已接受的规划反馈无法投影到短篇记忆。',
    }]);
  }
  const shortFeedbackRevisionQueue = initializeShortFeedbackRevisionQueue(
    task,
    result,
    {
      ...(result.feedback_impact_policy || {}),
      revision_groups: Array.isArray(result.revision_groups)
        ? result.revision_groups
        : Array.isArray(((task || {}).short_feedback_impact || {}).revision_groups)
          ? task.short_feedback_impact.revision_groups
          : [],
    },
  );
  if (String(shortFeedbackRevisionQueue.status || '').startsWith('blocked_')) {
    return blocked(shortFeedbackRevisionQueue.status, [{
      field: 'feedback_revision_queue',
      message: shortFeedbackRevisionQueue.message || '无法建立受影响小节修订队列。',
    }]);
  }
  reconcileShortRevisionQueueWithTitleLock(root, task);
  const memoryProjection = projectAcceptedMemoryUpdates(root, task, task.stage_execution || {}, result);
  let resultHistory;
  try {
    resultHistory = archiveAcceptedResultPacket(root, task, result);
  } catch (error) {
    resultHistory = { status: 'archive_failed', detail: String((error || {}).message || error || '') };
  }
  const projectionDecision = memoryProjectionAdvanceDecision(
    ((task.stage_execution || {}).memory_contract) || {},
    memoryProjection,
  );
  if (!projectionDecision.can_advance) {
    return holdAcceptedResultForMemoryProjection(root, task, result, resultFile, {
      memoryProjection,
      resultHistory,
      canonicalStageReceipt,
      shortSectionProjection,
      shortAssemblyProjection,
      shortFullStoryReviewProjection,
      shortFeedbackIntegration,
      shortPlanningMemoryProjection,
      shortFeedbackRevisionQueue,
    });
  }

  return finalizeAcceptedResult({
    root,
    task,
    result,
    resultFile,
    taskTemplate: registryCheck.template,
    reviewPlanValidation,
    memoryProjection,
    acceptanceContext: {
      canonicalStageReceipt,
      shortSectionProjection,
      shortAssemblyProjection,
      shortFullStoryReviewProjection,
      shortFeedbackIntegration,
      shortPlanningMemoryProjection,
      shortFeedbackRevisionQueue,
      resultHistory,
    },
  });
}

function finalizeAcceptedResult({
  root,
  task,
  result,
  resultFile,
  taskTemplate,
  reviewPlanValidation,
  memoryProjection,
  acceptanceContext = {},
}) {
  const canonicalStageReceipt = acceptanceContext.canonicalStageReceipt || { status: 'not_applicable' };
  const shortSectionProjection = acceptanceContext.shortSectionProjection || null;
  const shortAssemblyProjection = acceptanceContext.shortAssemblyProjection || null;
  const shortFullStoryReviewProjection = acceptanceContext.shortFullStoryReviewProjection || { status: 'not_applicable' };
  const shortFeedbackIntegration = acceptanceContext.shortFeedbackIntegration || { status: 'not_applicable' };
  const shortPlanningMemoryProjection = acceptanceContext.shortPlanningMemoryProjection || { status: 'not_applicable' };
  const shortFeedbackRevisionQueue = acceptanceContext.shortFeedbackRevisionQueue || { status: 'not_applicable' };
  const resultHistory = acceptanceContext.resultHistory || { status: 'not_available' };

  const briefFreshness = recordShortBriefFreshness(root, task, result);
  if (briefFreshness && briefFreshness.status !== 'snapshot_written') {
    return blocked('blocked_short_brief_snapshot', [{
      field: 'short_brief_freshness',
      message: 'Brief 阶段已回执，但 Brief 或其全篇规划依赖缺失，不能解锁正文。',
      details: briefFreshness,
    }]);
  }
  if (briefFreshness) task.short_brief_freshness = briefFreshness;

  if (task.workflow_type === 'review_repair' && task.current_stage === 'evidence_scan' && task.review_batches) {
    const batchTransition = completeReviewBatch(task.review_batches, result.batch_id, result.result_packet_path);
    if (String(batchTransition.status).startsWith('blocked_')) return blocked(batchTransition.status, JSON.stringify(batchTransition));
    if (batchTransition.status === 'batch_advanced') {
      const now = new Date().toISOString();
      const nextExpectedResultPacket = expectedReviewBatchResultPacket(task, batchTransition.next_batch.id);
      task.stage_execution = {
        ...(task.stage_execution || {}),
        status: 'completed',
        started_at: now,
        completed_at: now,
        result_packet: result.result_packet_path,
        expected_result_packet: nextExpectedResultPacket,
        batch_id: String(batchTransition.next_batch.id),
        batch_scope: String(batchTransition.next_batch.range || ''),
      };
      task.runtime_guard.heartbeat = {
        ...(task.runtime_guard.heartbeat || {}),
        updated_at: now,
        latest_trusted_artifact: result.result_packet_path,
        current_batch: batchTransition.next_batch.range,
      };
      task.runtime_guard.checkpoint_policy = {
        ...(task.runtime_guard.checkpoint_policy || {}),
        resume_from: `evidence_scan.batch-${batchTransition.next_batch.id}`,
        expected_result_packet: nextExpectedResultPacket,
      };
      task.machine.next_stop_reason = 'ready_next_review_batch';
      task.pending_action = {
        ...buildReviewBatchPendingAction(task, batchTransition.next_batch, reviewPlanValidation),
        status: 'pending',
      };
      const batchAutoStart = maybeAutoStartInternalStage(root, task, taskTemplate);
      writeTaskState(root, task);
      if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
      appendHistory(root, 'review_batch_completed', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: 'evidence_scan', step_id: `batch-${result.batch_id}` });
      return buildReviewAdvanceResponse(task, root, batchAutoStart);
    }
  }

  const advanced = advanceTask(task, result, root, taskTemplate);
  if (!['not_applicable', 'no_canonical_stage_writes'].includes(String(canonicalStageReceipt.status || ''))) {
    advanced.canonical_stage_receipt = canonicalStageReceipt;
  }
  if (shortSectionProjection && shortSectionProjection.applied) advanced.short_section_projection = shortSectionProjection;
  if (shortAssemblyProjection && shortAssemblyProjection.applied) advanced.short_story_assembly_projection = shortAssemblyProjection;
  if (shortFullStoryReviewProjection && shortFullStoryReviewProjection.status !== 'not_applicable') {
    advanced.short_full_story_review_projection = shortFullStoryReviewProjection;
  }
  if (shortFeedbackIntegration.status !== 'not_applicable') advanced.integration_event = shortFeedbackIntegration;
  if (shortPlanningMemoryProjection.status !== 'not_applicable') advanced.planning_memory_projection = shortPlanningMemoryProjection;
  if (shortFeedbackRevisionQueue.status !== 'not_applicable') advanced.feedback_revision_queue = task.feedback_revision_queue;
  advanced.memory_projection = memoryProjection;
  advanced.result_history = resultHistory;
  const autoStart = maybeAutoStartInternalStage(root, advanced, taskTemplate);
  if (advanced.status === 'completed') {
    const writeAudit = auditCanonicalWrites(root, advanced);
    advanced.canonical_write_audit = writeAudit;
    if (writeAudit.status === 'blocked_unreconciled_canonical_write') {
      blockTerminalCanonicalAudit(advanced, writeAudit, result, resultFile);
      writeTaskState(root, advanced);
      if (advanced.task_family_id) ensureTaskFamily(root, advanced, { write: true, projectLockHeld: true });
      appendHistory(root, 'canonical_write_audit_blocked', { workflow_id: advanced.workflow_id, workflow_type: advanced.workflow_type, stage_id: result.stage_id, step_id: result.step_id });
      return {
        schemaVersion: SCHEMA_VERSION,
        status: writeAudit.status,
        unmanaged_paths: writeAudit.unmanaged_paths,
        accepted_paths: writeAudit.accepted_paths,
        audit_file: writeAudit.audit_file || '',
      };
    }
  }
  writeTaskState(root, advanced);
  if (advanced.task_family_id) ensureTaskFamily(root, advanced, { write: true, projectLockHeld: true });
  appendHistory(root, 'applied_result', { workflow_id: advanced.workflow_id, workflow_type: advanced.workflow_type, stage_id: result.stage_id, step_id: result.step_id });
  if (advanced.status === 'completed') appendHistory(root, 'completed', advanced);
  if (advanced.workflow_type === 'review_repair') return buildReviewAdvanceResponse(advanced, root, autoStart);
  const continuation = autoStart.started ? runningStageResume(advanced, root) : null;
  const visibleResponse = continuation
    ? continuation.visible_response
    : pendingActionVisibleResponse(advanced, root, result.handoff_summary || '当前阶段已完成。');
  return {
    schemaVersion: SCHEMA_VERSION,
    status: autoStart.started ? 'stage_started' : 'advanced',
    task: advanced,
    current_stage: advanced.current_stage,
    remaining_stages: advanced.machine.remaining_stages,
    stage_execution: autoStart.stageExecution || null,
    pending_action: continuation ? null : refreshedVisibleMenu(advanced, root),
    next_candidates: continuation ? [] : (visibleResponse.options || []),
    visible_response: visibleResponse,
    interaction_contract: continuation ? 'continue_confirmed_internal_stage' : 'render_visible_response_text_verbatim',
  };
}

function validateShortSectionAcceptanceResult(projectRoot, task, result) {
  const shortWorkflowTypes = new Set(['short_write', 'short_startup', 'private_short_startup']);
  if (!shortWorkflowTypes.has(String(task.workflow_type || ''))
    || String(task.current_stage || '') !== 'section_accept_anchor') return null;
  if (!result.section_acceptance || typeof result.section_acceptance !== 'object') {
    return blocked('blocked_short_section_acceptance_proof_missing', [{
      field: 'section_acceptance',
      message: '采用当前节前必须提供与当前正文绑定的验收证明；补写或改写后旧证明自动失效。',
    }]);
  }
  const proof = validateShortSectionAcceptanceProof({
    projectRoot,
    workflowId: task.workflow_id,
    proof: result.section_acceptance,
    requireCommit: Number(task.result_contract_version || 1) >= 2,
  });
  const revisionQueue = activeShortFeedbackRevision(task);
  if (revisionQueue && Number(result.section_acceptance.section_index || 0) !== Number(revisionQueue.current_section_index || 0)) {
    return blocked('blocked_feedback_revision_section_mismatch', [{
      field: 'section_acceptance.section_index',
      message: '当前采用的小节不是修订队列正在等待的小节。',
      expected_section: Number(revisionQueue.current_section_index || 0),
      actual_section: Number(result.section_acceptance.section_index || 0),
    }]);
  }
  if (proof.status === 'accepted') return null;
  return blocked('blocked_short_section_acceptance_proof_invalid', [{
    field: 'section_acceptance',
    reason_code: proof.code || 'short_section_acceptance_proof_invalid',
    message: '当前节验收证明无效，必须重新执行机器门、故事价值门、重复退化门和动态篇幅门后才能生成下一节 Brief。',
  }]);
}

function projectAcceptedShortSection(projectRoot, task, result) {
  const shortWorkflowTypes = new Set(['short_write', 'short_startup', 'private_short_startup']);
  if (!shortWorkflowTypes.has(String(task.workflow_type || ''))
    || Number(task.result_contract_version || 1) < 2
    || String(task.current_stage || '') !== 'section_accept_anchor') return null;
  const proof = result.section_acceptance && typeof result.section_acceptance === 'object'
    ? result.section_acceptance
    : null;
  if (!proof) return null;
  const sectionIndex = Number(proof.section_index || 0);
  const plannedSections = Number(result.planned_sections || 0);
  if (!Number.isInteger(sectionIndex) || sectionIndex < 1 || !Number.isInteger(plannedSections) || plannedSections < sectionIndex) {
    return {
      blocked: blocked('blocked_short_section_projection_invalid', [{
        field: 'section_acceptance',
        message: '采用回执缺少有效的小节序号或全篇规划节数，不能推进项目状态。',
      }]),
    };
  }

  const stateFile = resolveSafeProjectFile(projectRoot, '追踪/private-short-extension/project-state.json');
  const state = stateFile && fs.existsSync(stateFile) ? readJson(stateFile) : {};
  if (!state || state.__error) {
    return {
      blocked: blocked('blocked_short_project_state_invalid', [{
        field: 'project-state.json',
        message: '短篇项目状态不可读，正式小节已保留，但不能推进下一阶段。',
      }]),
    };
  }

  const accepted = (Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
    .filter((item) => Number((item || {}).section_index) !== sectionIndex);
  accepted.push({
    section_index: sectionIndex,
    title: String(proof.section_title || `第${sectionIndex}节`),
    canonical_path: String(proof.canonical_path || ''),
    anchor_path: String(proof.anchor_path || ''),
    sha256: String(proof.canonical_sha256 || ''),
    section_commit_id: String(proof.section_commit_id || ''),
    length_chars: Number(proof.length_chars || 0),
    quality_status: String(proof.quality_status || 'machine_and_story_gates_passed'),
  });
  accepted.sort((left, right) => Number(left.section_index) - Number(right.section_index));
  const revisionAdvance = acceptShortFeedbackRevisionSection(task, sectionIndex, {
    section_commit_id: String(proof.section_commit_id || ''),
  });
  if (String(revisionAdvance.status || '').startsWith('blocked_')) {
    return {
      blocked: blocked(revisionAdvance.status, [{
        field: 'feedback_revision_queue',
        message: '修订小节与当前队列游标不一致，不能推进。',
        expected_section: revisionAdvance.expected_section,
        actual_section: revisionAdvance.actual_section,
      }]),
    };
  }
  if (revisionAdvance.status !== 'not_applicable') {
    const queueCompleted = revisionAdvance.status === 'feedback_revision_queue_completed';
    const canonicalAssets = [...new Set([
      ...(Array.isArray(state.canonical_assets) ? state.canonical_assets : []),
      String(proof.canonical_path || ''),
      String(proof.anchor_path || ''),
    ].filter(Boolean))];
    const assetStatus = {
      ...(state.asset_status && typeof state.asset_status === 'object' ? state.asset_status : {}),
      [String(proof.canonical_path || '')]: `section_${String(sectionIndex).padStart(3, '0')}_accepted`,
      [String(proof.anchor_path || '')]: 'current',
    };
    writeJson(stateFile, {
      ...state,
      current_section_index: queueCompleted ? sectionIndex : revisionAdvance.next_section,
      accepted_sections: accepted,
      status: queueCompleted ? 'feedback_revision_completed' : `feedback_revision_section_${String(sectionIndex).padStart(3, '0')}_accepted`,
      current_stage: queueCompleted ? 'full_story_assembly' : 'next_section_brief',
      next_required_action: queueCompleted
        ? '重新组装全部已采用小节并执行全篇检查'
        : `重建并复检第${revisionAdvance.next_section}节`,
      canonical_assets: canonicalAssets,
      asset_status: assetStatus,
      updated_at: new Date().toISOString(),
    });
    return {
      applied: true,
      section_index: sectionIndex,
      section_commit_id: String(proof.section_commit_id || ''),
      feedback_revision: true,
      revision_queue_completed: queueCompleted,
      next_section: revisionAdvance.next_section,
    };
  }
  const sequence = accepted.map((item) => Number(item.section_index));
  const expectedSequence = Array.from({ length: sectionIndex }, (_, index) => index + 1);
  if (sequence.length < sectionIndex || expectedSequence.some((value, index) => sequence[index] !== value)) {
    return {
      blocked: blocked('blocked_short_section_projection_gap', [{
        field: 'accepted_sections',
        message: '采用记录存在前置缺节，正式小节已保留；补齐缺节后再推进工作流。',
        accepted_sections: sequence,
      }]),
    };
  }

  const completed = Boolean(result.all_sections_completed) && sectionIndex === plannedSections;
  const remaining = Array.from({ length: Math.max(0, plannedSections - sectionIndex) }, (_, index) => sectionIndex + index + 1);
  const canonicalAssets = [...new Set([
    ...(Array.isArray(state.canonical_assets) ? state.canonical_assets : []),
    String(proof.canonical_path || ''),
    String(proof.anchor_path || ''),
  ].filter(Boolean))];
  const assetStatus = {
    ...(state.asset_status && typeof state.asset_status === 'object' ? state.asset_status : {}),
    [String(proof.canonical_path || '')]: `section_${String(sectionIndex).padStart(3, '0')}_accepted`,
    [String(proof.anchor_path || '')]: 'current',
  };
  writeJson(stateFile, {
    ...state,
    current_section_index: sectionIndex,
    accepted_sections: accepted,
    remaining_sections: remaining,
    status: completed ? 'all_sections_accepted' : `section_${String(sectionIndex).padStart(3, '0')}_accepted`,
    current_stage: completed ? 'full_story_assembly' : 'next_section_brief',
    next_required_action: completed
      ? `组装已采用的 1-${plannedSections} 节并进行全篇检查`
      : `生成第${sectionIndex + 1}节 Brief`,
    canonical_assets: canonicalAssets,
    asset_status: assetStatus,
    updated_at: new Date().toISOString(),
  });
  return {
    applied: true,
    section_index: sectionIndex,
    section_commit_id: String(proof.section_commit_id || ''),
    all_sections_completed: completed,
    next_section: completed ? null : sectionIndex + 1,
  };
}

function validateShortStoryAssemblyResult(projectRoot, task, result) {
  const shortWorkflowTypes = new Set(['short_write', 'short_startup', 'private_short_startup']);
  if (!shortWorkflowTypes.has(String(task.workflow_type || ''))
    || String(task.current_stage || '') !== 'full_story_assembly') return null;
  const proof = result.short_story_assembly && typeof result.short_story_assembly === 'object'
    ? result.short_story_assembly
    : null;
  if (!proof) return blocked('blocked_short_story_assembly_proof_missing', [{
    field: 'short_story_assembly',
    message: '全文组装必须提供确定性合稿证明，不能用手工 result packet 跳过缺节检查。',
  }]);
  const planned = Number(proof.planned_sections || 0);
  const assembled = Number(proof.assembled_sections || 0);
  if (!Number.isInteger(planned) || planned < 1 || assembled !== planned) {
    return blocked('blocked_short_story_assembly_count_mismatch', [{
      field: 'assembled_sections',
      message: '组装节数与锁定规划不一致。',
      planned_sections: planned,
      assembled_sections: assembled,
    }]);
  }
  const canonicalPath = String(proof.canonical_path || '');
  const canonicalFile = resolveSafeProjectFile(projectRoot, canonicalPath);
  if (!canonicalFile || !fs.existsSync(canonicalFile) || normalizeContentHash(hashFile(canonicalFile)) !== normalizeContentHash(proof.canonical_sha256)) {
    return blocked('blocked_short_story_assembly_hash_mismatch', [{ field: 'canonical_path', message: '全文稿缺失或已在组装后发生变化。' }]);
  }
  const commitId = String(proof.assembly_commit_id || '');
  const inspected = inspectChapter(projectRoot, '短篇发布稿', 1);
  const commit = inspected.latest_commit;
  if (!commit || String(commit.commit_id || '') !== commitId || String(commit.workflow_id || '') !== String(task.workflow_id || '')) {
    return blocked('blocked_short_story_assembly_commit_missing', [{ field: 'assembly_commit_id', message: '全文稿没有已接受的事务提交。' }]);
  }
  const artifact = (commit.artifacts || []).find((item) => String(item.target || '') === canonicalPath);
  if (!artifact || normalizeContentHash(artifact.after_hash || artifact.content_hash) !== normalizeContentHash(proof.canonical_sha256)) {
    return blocked('blocked_short_story_assembly_commit_mismatch', [{ field: 'assembly_commit_id', message: '全文稿与事务提交内容不一致。' }]);
  }
  return null;
}

function projectShortStoryAssembly(projectRoot, task, result) {
  const shortWorkflowTypes = new Set(['short_write', 'short_startup', 'private_short_startup']);
  if (!shortWorkflowTypes.has(String(task.workflow_type || ''))
    || String(task.current_stage || '') !== 'full_story_assembly') return null;
  const proof = result.short_story_assembly && typeof result.short_story_assembly === 'object'
    ? result.short_story_assembly
    : null;
  if (!proof) return null;
  const stateFile = resolveSafeProjectFile(projectRoot, '追踪/private-short-extension/project-state.json');
  const state = stateFile && fs.existsSync(stateFile) ? readJson(stateFile) : {};
  if (!state || state.__error) return { blocked: blocked('blocked_short_project_state_invalid', '短篇项目状态不可读。') };
  const planned = Number(proof.planned_sections || 0);
  const acceptedCount = Array.isArray(state.accepted_sections) ? state.accepted_sections.length : 0;
  if (acceptedCount !== planned) {
    return { blocked: blocked('blocked_short_story_assembly_state_mismatch', [{ field: 'accepted_sections', message: '项目采用记录与组装计划不一致。', accepted_sections: acceptedCount, planned_sections: planned }]) };
  }
  const canonicalPath = String(proof.canonical_path || '正文.md');
  const nextStage = String(proof.next_stage_id || result.next_stage_id || 'full_story_review');
  writeJson(stateFile, {
    ...state,
    status: 'full_story_assembled',
    current_stage: nextStage,
    current_section_index: planned,
    remaining_sections: [],
    canonical_assets: [...new Set([...(Array.isArray(state.canonical_assets) ? state.canonical_assets : []), canonicalPath])],
    asset_status: {
      ...(state.asset_status && typeof state.asset_status === 'object' ? state.asset_status : {}),
      [canonicalPath]: `sections_001_${String(planned).padStart(3, '0')}_assembled`,
    },
    assembly_commit_id: String(proof.assembly_commit_id || ''),
    next_required_action: '执行全篇总编辑验收；通过后再做表达清理与最终检查',
    updated_at: new Date().toISOString(),
  });
  return { applied: true, planned_sections: planned, assembly_commit_id: String(proof.assembly_commit_id || '') };
}

function validateShortFullStoryReviewResult(projectRoot, task, result) {
  const shortWorkflowTypes = new Set(['short_write', 'short_startup', 'private_short_startup']);
  if (!shortWorkflowTypes.has(String(task.workflow_type || ''))
    || String(task.current_stage || '') !== 'full_story_review') return null;
  const proof = result.short_full_story_review && typeof result.short_full_story_review === 'object'
    ? result.short_full_story_review
    : null;
  if (!proof) return blocked('blocked_short_full_story_review_proof_missing', [{ field: 'short_full_story_review', message: '全篇验收必须提供结构化审阅证明。' }]);
  const storyFile = resolveSafeProjectFile(projectRoot, String(proof.story_path || '正文.md'));
  if (!storyFile || !fs.existsSync(storyFile)) return blocked('blocked_short_full_story_review_story_missing', [{ field: 'story_path', message: '全篇验收对应正文不存在。' }]);
  if (normalizeContentHash(hashFile(storyFile)) !== normalizeContentHash(proof.story_sha256)) {
    return blocked('blocked_short_full_story_review_story_changed', [{ field: 'story_sha256', message: '正文已在全篇审阅后变化，必须重新验收。' }]);
  }
  const evidenceFile = resolveSafeProjectFile(projectRoot, String(proof.evidence_pack_path || ''));
  const reviewFile = resolveSafeProjectFile(projectRoot, String(proof.review_card_path || ''));
  if (!evidenceFile || !reviewFile || !fs.existsSync(evidenceFile) || !fs.existsSync(reviewFile)) {
    return blocked('blocked_short_full_story_review_artifact_missing', [{ field: 'review_card_path', message: '全篇证据包或审阅卡缺失。' }]);
  }
  if (normalizeContentHash(hashFile(reviewFile)) !== normalizeContentHash(proof.review_card_sha256)) {
    return blocked('blocked_short_full_story_review_card_changed', [{ field: 'review_card_sha256', message: '全篇审阅卡在回执生成后发生变化。' }]);
  }
  const evidencePack = readJson(evidenceFile);
  const card = readJson(reviewFile);
  if (!evidencePack || evidencePack.__error || !card || card.__error) {
    return blocked('blocked_short_full_story_review_artifact_invalid', [{ field: 'review_card_path', message: '全篇证据包或审阅卡不可读。' }]);
  }
  attachEvidenceRuntime(evidencePack, storyFile);
  const validation = validateEditorialReviewCard(card, evidencePack);
  if (validation.status !== 'valid') return blocked('blocked_short_full_story_review_invalid', validation.findings);
  const decision = String(proof.decision || '');
  if (decision !== String(card.decision || '')) return blocked('blocked_short_full_story_review_decision_mismatch', [{ field: 'decision', message: '结果包与审阅卡结论不一致。' }]);
  const expectedNext = decision === 'pass'
    ? ((String(task.workflow_profile || '') === 'private' || String(task.workflow_owner || '') === 'private-short-extension') ? 'short_deslop' : 'deslop')
    : 'feedback_impact_sync';
  if (String(result.next_stage_id || '') !== expectedNext) {
    return blocked('blocked_short_full_story_review_next_invalid', [{ field: 'next_stage_id', message: `全篇验收 ${decision} 必须进入 ${expectedNext}。` }]);
  }
  return null;
}

function projectShortFullStoryReview(projectRoot, task, result) {
  if (String(task.current_stage || '') !== 'full_story_review') return { status: 'not_applicable' };
  const proof = result.short_full_story_review && typeof result.short_full_story_review === 'object'
    ? result.short_full_story_review
    : null;
  if (!proof) return { status: 'not_applicable' };
  const decision = String(proof.decision || '');
  task.short_full_story_review = {
    decision,
    visible_verdict: String(proof.visible_verdict || (decision === 'pass' ? 'story_ready' : 'revision_required')),
    visible_label: String(proof.visible_label || (decision === 'pass' ? '故事层可进入表达清理' : '故事层需先回炉')),
    story_sha256: String(proof.story_sha256 || ''),
    evidence_pack_path: String(proof.evidence_pack_path || ''),
    review_card_path: String(proof.review_card_path || ''),
    review_card_sha256: String(proof.review_card_sha256 || ''),
    accepted_at: new Date().toISOString(),
  };
  if (decision !== 'revise') return { status: 'review_passed', finding_count: 0 };
  const findings = Array.isArray(proof.findings) ? proof.findings : [];
  for (const finding of findings) {
    const text = [
      `全篇总编辑发现 ${String((finding || {}).code || 'StoryIssue')}（${String((finding || {}).severity || 'S3')}）。`,
      `影响范围：${String((finding || {}).scope || '全篇')}。`,
      `正文证据：${String((finding || {}).evidence_quote || '')}。`,
      `建议回写：${String((finding || {}).repair_direction || '')}。`,
    ].join('\n');
    enqueueShortFeedback(projectRoot, task, text, {
      classification: 'scope_change',
      scopeSnapshot: '全篇',
      previousStage: 'full_story_review',
      sourceKind: 'editorial_review',
    });
  }
  return { status: 'review_revision_queued', finding_count: findings.length, feedback_id: String(((task.pending_feedback || {}).feedback_id) || '') };
}

function archiveAcceptedResultPacket(projectRoot, task, result) {
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const stageId = String(result.stage_id || execution.stage_id || 'stage').replace(/[^A-Za-z0-9._-]/g, '_');
  const attemptId = String(execution.stage_attempt_id || 'attempt').replace(/[^A-Za-z0-9._-]/g, '_');
  const sectionIndex = Number(result.current_section_index || ((result.section_acceptance || {}).section_index) || 0);
  const scopeDir = Number.isInteger(sectionIndex) && sectionIndex > 0
    ? `section-${String(sectionIndex).padStart(3, '0')}`
    : 'workflow';
  const archiveRel = `${task.task_dir}/result-history/${stageId}/${scopeDir}/${attemptId}.result.json`;
  const archiveFile = resolveSafeProjectFile(projectRoot, archiveRel);
  if (!archiveFile) return { status: 'archive_path_unsafe', path: archiveRel };
  const archived = {
    ...result,
    result_history_path: archiveRel,
    archived_at: new Date().toISOString(),
  };
  atomicWriteJson(archiveFile, archived);
  return { status: 'archived', path: archiveRel, stage_id: stageId, stage_attempt_id: execution.stage_attempt_id || '', section_index: sectionIndex || null };
}

function buildReviewAdvanceResponse(task, root, autoStart = { started: false, stageExecution: null }) {
  const summary = buildReviewAdvanceSummary(task, templates());
  if (autoStart.started) {
    const continuation = runningStageResume(task, root);
    return {
      ...summary,
      status: 'stage_started',
      task,
      current_stage: String(task.current_stage || ''),
      remaining_stages: Array.isArray((task.machine || {}).remaining_stages) ? task.machine.remaining_stages : [],
      stage_execution: autoStart.stageExecution || null,
      pending_action: null,
      next_candidates: [],
      visible_response: continuation ? continuation.visible_response : null,
      interaction_contract: 'continue_confirmed_internal_stage',
    };
  }
  const visibleResponse = pendingActionVisibleResponse(task, root, '当前审阅批次已完成。');
  return {
    ...summary,
    task,
    current_stage: String(task.current_stage || ''),
    remaining_stages: Array.isArray((task.machine || {}).remaining_stages) ? task.machine.remaining_stages : [],
    pending_action: refreshedVisibleMenu(task, root),
    next_candidates: visibleResponse.options || [],
    visible_response: visibleResponse,
    interaction_contract: 'render_visible_response_text_verbatim',
  };
}

function maybeAutoStartInternalStage(root, task, taskTemplate) {
  if (!task || !['running', 'paused_after_step'].includes(String(task.status || ''))) {
    return { started: false, stageExecution: null };
  }
  const tpl = taskTemplate || (resolvedTemplateForTask(task).template);
  const stageDef = findStage(tpl, task.current_stage);
  if (!stageDef || stageDef.requires_user_confirm) return { started: false, stageExecution: null };
  const selectedAt = new Date().toISOString();
  task.pending_action = null;
  return maybeStartStageExecution(root, task, {
    action_id: 'auto_continue_internal',
    selected_number: 0,
    target_stage: stageDef.stage_id,
    risk_level: stageDef.risk_level || 'medium',
    execution_contract: { completion_boundary: 'stage_completed' },
  }, selectedAt, null);
}

function blockTerminalCanonicalAudit(task, audit, result, resultFile, phase = 'terminal') {
  const now = new Date().toISOString();
  task.status = 'blocked';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'blocked';
  task.lifecycle.updated_at = now;
  task.machine = normalizeMachine(task, templates()[task.workflow_type]);
  task.machine.last_transition = 'canonical_write_audit_blocked';
  task.machine.next_stop_reason = 'canonical_write_audit_blocked';
  task.machine.allowed_actions = ['controlled_commit', 'recheck_canonical_audit'];
  task.canonical_write_audit_block = {
    status: audit.status,
    blocked_at: now,
    result_packet_path: String(result.result_packet_path || ''),
    result_packet_hash: hashFile(resultFile),
    stage_id: String(result.stage_id || ''),
    phase,
    result_packet_validated_before_audit: phase === 'pre_apply',
    audit_file: String(audit.audit_file || ''),
    next_step: '受控提交后复检 canonical audit。',
  };
  task.pending_action = decoratePendingAction({
    id: `pa-canonical-audit-${task.workflow_id || 'workflow'}`,
    question: '正式资产存在未受控改写，需先完成受控提交或复检。',
    options: [
      { number: 1, action_id: 'controlled_commit', label: '受控提交并生成 receipt', risk_level: 'high' },
      { number: 2, action_id: 'recheck_canonical_audit', label: '复检 canonical audit', risk_level: 'low' },
    ],
    free_text_enabled: false,
  });
}

function stageCanonicalWriteSet(result) {
  const candidates = [
    ...arrayOrEmpty((result || {}).result_write_set),
    ...arrayOrEmpty((result || {}).changed_assets),
    ...arrayOrEmpty((result || {}).changed_files),
    ...arrayOrEmpty((result || {}).created_files),
  ];
  return Array.from(new Set(candidates.map(item => String(item || '').trim()).filter(Boolean)));
}

function arrayOrEmpty(value) {
  return Array.isArray(value) ? value : [];
}

function recoverTerminalCanonicalAudit(root, task, result, resultFile) {
  const block = task.canonical_write_audit_block;
  if (!block || block.status === 'resolved') return null;
  if (String(block.result_packet_path || '') !== String(result.result_packet_path || '')) return null;
  if (String(block.result_packet_hash || '') !== hashFile(resultFile)) return null;

  const audit = auditCanonicalWrites(root, task, String(block.phase || '') === 'pre_apply'
    ? { declaredWriteSet: stageCanonicalWriteSet(result) }
    : {});
  task.canonical_write_audit = audit;
  if (audit.status === 'blocked_unreconciled_canonical_write') {
    blockTerminalCanonicalAudit(task, audit, result, resultFile, String(block.phase || 'terminal'));
    writeTaskState(root, task);
    appendHistory(root, 'canonical_write_audit_recheck_blocked', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: result.stage_id, step_id: result.step_id });
    return { schemaVersion: SCHEMA_VERSION, status: audit.status, unmanaged_paths: audit.unmanaged_paths, accepted_paths: audit.accepted_paths, audit_file: audit.audit_file || '' };
  }

  if (String(block.phase || '') === 'pre_apply') {
    task.status = 'running';
    task.lifecycle = normalizeLifecycle(task);
    task.lifecycle.status = 'active';
    task.lifecycle.completed_at = '';
    task.lifecycle.updated_at = new Date().toISOString();
    task.canonical_write_audit_block = { ...block, status: 'resolved', resolved_at: new Date().toISOString(), next_step: '' };
    task.pending_action = null;
    writeTaskState(root, task);
    appendHistory(root, 'canonical_write_audit_recovered', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: result.stage_id, step_id: result.step_id, phase: 'pre_apply' });
    return null;
  }

  const now = new Date().toISOString();
  task.status = 'completed';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'completed';
  task.lifecycle.completed_at = task.lifecycle.completed_at || now;
  task.lifecycle.updated_at = now;
  task.machine = normalizeMachine(task, templates()[task.workflow_type]);
  task.machine.last_transition = 'canonical_write_audit_recovered';
  task.machine.next_stop_reason = 'completed';
  task.machine.allowed_actions = [];
  task.canonical_write_audit_block = { ...block, status: 'resolved', resolved_at: now, next_step: '' };
  task.pending_action = buildCompletionPendingAction(task, task.recommended_next || []);
  writeTaskState(root, task);
  if (task.task_family_id) ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
  appendHistory(root, 'canonical_write_audit_recovered', { workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: result.stage_id, step_id: result.step_id });
  appendHistory(root, 'completed', task);
  return { schemaVersion: SCHEMA_VERSION, status: 'advanced', task, current_stage: task.current_stage, remaining_stages: task.machine.remaining_stages };
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function normalizeContentHash(value) {
  return String(value || '').replace(/^sha256:/, '');
}

function validateResultAgainstTask(task, result, projectRoot, resultFile, taskTemplate) {
  const findings = [];
  for (const field of ['workflow_id', 'workflow_type', 'stage_id', 'step_id', 'step_status']) {
    if (!result || !result[field]) findings.push({ field, message: 'result packet 缺少必填字段。' });
  }
  if (result && result.workflow_id && result.workflow_id !== task.workflow_id) findings.push({ field: 'workflow_id', message: 'result packet workflow_id 与当前任务不一致。' });
  if (result && result.workflow_type && result.workflow_type !== task.workflow_type) findings.push({ field: 'workflow_type', message: 'result packet workflow_type 与当前任务不一致。' });
  if (result && result.stage_id && result.stage_id !== task.current_stage) findings.push({ field: 'stage_id', message: 'result packet stage_id 与 current_stage 不一致。' });
  if (result && !['completed', 'blocked', 'failed', 'skipped'].includes(String(result.step_status || ''))) findings.push({ field: 'step_status', message: 'result packet step_status 非法。' });
  const tpl = taskTemplate;
  const stageDef = findStage(tpl, task.current_stage);
  const expectedOwner = String(((task.stage_execution || {}).owner_module) || (stageDef || {}).owner_module || task.workflow_owner || '');
  const actualOwner = String((result || {}).owner_module || '');
  const privateWorkflow = String(task.workflow_profile || '') === 'private'
    || String(((task.workflow_registry || {}).profile) || '') === 'private';
  if (expectedOwner && actualOwner && actualOwner !== expectedOwner) {
    findings.push({
      field: 'owner_module',
      message: 'result packet owner 与当前阶段权威 owner 不一致，禁止公有/私有短篇串线。',
      expected: expectedOwner,
      actual: actualOwner,
    });
  } else if (Number(task.result_contract_version || 1) >= 2 && expectedOwner && !actualOwner) {
    findings.push({
      field: 'owner_module',
      message: 'v2 result packet 必须声明当前阶段权威 owner，禁止通过缺省值绕过模块边界。',
      expected: expectedOwner,
      actual: '',
    });
  }
  if (findings.length > 0) return { schemaVersion: SCHEMA_VERSION, status: 'blocked_result_packet_invalid', findings };
  if (Number(task.result_contract_version || 1) >= 2) {
    const requiredV2 = RESULT_CONTRACT_V2_FIELDS;
    const missingV2 = requiredV2.filter((field) => result[field] === undefined || result[field] === null);
    if (missingV2.length > 0) {
      return {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_result_packet_incomplete',
        findings: missingV2.map((field) => ({ field, message: 'v2 result packet 缺少必填字段。' })),
      };
    }
    const executionValidation = validateV2ExecutionBinding(task, result, projectRoot, resultFile, taskTemplate);
    if (executionValidation) return executionValidation;
    const unitBindingValidation = validateResultPacketUnitBinding(task, result);
    if (unitBindingValidation) return { schemaVersion: SCHEMA_VERSION, ...unitBindingValidation };
    const managedMemoryValidation = validateManagedRunnerMemoryReceipt(task, result, projectRoot);
    if (managedMemoryValidation) return managedMemoryValidation;
    const interactiveLongMemoryValidation = validateInteractiveLongMemoryReceipt(task, result, projectRoot);
    if (interactiveLongMemoryValidation) return interactiveLongMemoryValidation;
    const shortMemoryValidation = validateShortResultMemoryReceipt(task, result, projectRoot);
    if (shortMemoryValidation) return shortMemoryValidation;
    const longformContractValidation = validateLongformResultContract(task, result);
    if (longformContractValidation) return longformContractValidation;
    if (task.workflow_type === 'long_write') {
      const missingLongform = LONG_WRITE_RESULT_FIELDS.filter((field) => result[field] === undefined || result[field] === null);
      if (missingLongform.length > 0) {
        return {
          schemaVersion: SCHEMA_VERSION,
          status: 'blocked_result_packet_incomplete',
          findings: missingLongform.map((field) => ({ field, message: 'long_write v2 result packet 缺少必填字段。' })),
        };
      }
    }
    const longformWriteSetValidation = validateLongformWriteSet(task, result, projectRoot);
    if (longformWriteSetValidation) return longformWriteSetValidation;
  }
  const role = currentUnitRole((tpl && tpl.unit_lifecycle_contract) || unitLifecycle('workflow_batch', {}), task.current_stage);
  const reviewValidation = validateLongformReviewAcceptance(task, result, stageDef);
  if (reviewValidation) return reviewValidation;
  if ((role === 'machine_quality_gate' || /(^|_)machine_gate$/.test(String(task.current_stage || ''))) && WORKFLOW_TRANSITIONS.machineGateResultIsAmbiguous(result)) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_machine_gate_result_ambiguous',
      findings: [
        {
          field: 'machine_gate_result',
          message: `机器门 result packet 缺少明确 pass/blocking 证据：${stageDef ? stageDef.stage_id : task.current_stage} 必须提供 machine_gate_result / verification_result / output_health_result / gate_result 或 blocking_findings。`,
        },
      ],
    };
  }
  const chapterCommitValidation = validateChapterCommit(projectRoot, task, result);
  if (chapterCommitValidation) return chapterCommitValidation;
  const evidenceScanValidation = validateEvidenceScanReceipt(task, result, projectRoot);
  if (evidenceScanValidation) return evidenceScanValidation;
  return { schemaVersion: SCHEMA_VERSION, status: 'ok', findings: [] };
}

function validateManagedRunnerMemoryReceipt(task, result, projectRoot) {
  if (String(result.step_status || '') !== 'completed'
      || String(result.host_execution_mode || '') !== 'managed_runner') return null;
  const runnerRel = String(result.runner_packet_path || '');
  const runnerFile = resolveSafeProjectFile(projectRoot, runnerRel);
  if (!runnerFile || !fs.existsSync(runnerFile)) {
    return blocked('blocked_managed_runner_receipt_missing', [{
      field: 'runner_packet_path',
      message: '托管执行回执缺少可核验的 runner packet，不能接受该阶段结果。',
    }]);
  }
  const runner = readJson(runnerFile);
  if (!runner || runner.__error
      || String(runner.workflow_id || '') !== String(task.workflow_id || '')
      || String(runner.stage_id || '') !== String(result.stage_id || '')) {
    return blocked('blocked_managed_runner_receipt_scope_mismatch', [{
      field: 'runner_packet_path',
      message: 'runner packet 与当前 workflow/stage 不一致。',
    }]);
  }
  const expected = (((runner || {}).memory_context || {}).memory_read_receipt) || null;
  if (!expected) return null;
  const contract = (((runner || {}).memory_context || {}).memory_contract) || null;
  const validation = validateMemoryReadReceipt(contract, result.memory_read_receipt);
  if (validation.status !== 'current') {
    return blocked('blocked_managed_memory_receipt_invalid', [{
      field: 'memory_read_receipt',
      message: '阶段结果没有回显本次托管运行实际读取的记忆合同。',
      memory_status: validation.status,
      stale_fields: validation.stale_fields || [],
    }]);
  }
  let currentDigests = {};
  try { currentDigests = new StoryMemoryRepository(projectRoot).sourceRevisions(); } catch (_) { currentDigests = {}; }
  const expectedDigests = expected.source_digests && typeof expected.source_digests === 'object'
    ? expected.source_digests
    : {};
  const staleSources = [...new Set([...Object.keys(expectedDigests), ...Object.keys(currentDigests)])]
    .filter((key) => String(expectedDigests[key] || '') !== String(currentDigests[key] || ''));
  if (staleSources.length) {
    return blocked('blocked_managed_memory_context_stale', [{
      field: 'memory_read_receipt.source_digests',
      message: '托管阶段执行期间作品记忆发生变化，必须用新上下文包复核当前阶段。',
      stale_sources: staleSources,
    }]);
  }
  return null;
}

function validateInteractiveLongMemoryReceipt(task, result, projectRoot) {
  if (String(task.workflow_type || '') !== 'long_write'
      || !LONG_EXECUTABLE_STAGE_CONTRACTS.has(String(result.stage_id || ''))
      || String(result.step_status || '') !== 'completed'
      || String(result.host_execution_mode || '') === 'managed_runner') return null;
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  if (Number(execution.memory_contract_version || 0) < 2) return null;
  const memoryContext = execution.memory_context && typeof execution.memory_context === 'object'
    ? execution.memory_context
    : {};
  const contract = memoryContext.memory_contract || null;
  const expected = memoryContext.memory_read_receipt || null;
  if (!contract || !expected) {
    return blocked('blocked_interactive_memory_context_missing', [{
      field: 'stage_execution.memory_context',
      message: '交互式长篇阶段缺少启动时绑定的记忆合同，不能把结果当作已读取当前作品记忆。',
    }]);
  }
  const validation = validateMemoryReadReceipt(contract, result.memory_read_receipt);
  if (validation.status !== 'current') {
    return blocked('blocked_interactive_memory_receipt_invalid', [{
      field: 'memory_read_receipt',
      message: '交互式长篇结果没有回显本阶段实际读取的记忆合同。',
      memory_status: validation.status,
      stale_fields: validation.stale_fields || [],
    }]);
  }
  let currentDigests = {};
  try { currentDigests = new StoryMemoryRepository(projectRoot).sourceRevisions(); } catch (_) { currentDigests = {}; }
  const expectedDigests = expected.source_digests && typeof expected.source_digests === 'object' ? expected.source_digests : {};
  const staleSources = [...new Set([...Object.keys(expectedDigests), ...Object.keys(currentDigests)])]
    .filter((key) => String(expectedDigests[key] || '') !== String(currentDigests[key] || ''));
  if (staleSources.length > 0) {
    return blocked('blocked_interactive_memory_context_stale', [{
      field: 'memory_read_receipt.source_digests',
      message: '交互阶段执行期间作品记忆已经变化，必须重建最小上下文再复核当前阶段。',
      stale_sources: staleSources,
    }]);
  }
  return null;
}

function validateShortResultMemoryReceipt(task, result, projectRoot) {
  if (!isShortWritingWorkflow(task) || String(result.step_status || '') !== 'completed') return null;
  const execution = task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : {};
  if (!execution.stage_context_packet
      || String(((execution.memory_context || {}).context_source) || '') !== 'stage_context') return null;
  const validation = checkShortMemoryStage({
    projectRoot,
    task,
    execution,
    sectionIndex: Number(execution.section_index || result.current_section_index || ((result.section_acceptance || {}).section_index) || 0) || undefined,
    stageId: String(result.stage_id || execution.stage_id || task.current_stage || ''),
  });
  if (!validation.blocking) return null;
  return blocked('blocked_short_memory_context_stale', [{
    field: 'memory_read_receipt',
    message: validation.instruction || '当前阶段使用的作品记忆已经过期，必须重建最小上下文后复核当前单元。',
    memory_status: validation.memory_status,
    stale_sources: validation.stale_sources,
    resume_stage: validation.resume_stage,
  }]);
}

function validateLongformWriteSet(task, result, projectRoot) {
  if (task.workflow_type !== 'long_write') return null;
  const symlinkValidation = validateLongformProjectTreeSymlinks(projectRoot);
  if (symlinkValidation) return symlinkValidation;
  const stageDef = findStage(templates().long_write, task.current_stage) || {};
  const authorized = Array.isArray(stageDef.write_set) ? stageDef.write_set : [];
  const executionWriteSet = (task.stage_execution || {}).write_set;
  const findings = [];
  if (!Array.isArray(executionWriteSet) || !sameContractValue(executionWriteSet, authorized)) {
    findings.push({
      field: 'stage_execution.write_set',
      message: 'long_write 活动阶段写集必须匹配不可变模板授权。',
      expected: authorized,
      actual: executionWriteSet,
    });
  }
  if (!Array.isArray(result.result_write_set)) {
    findings.push({ field: 'result_write_set', message: 'result_write_set 必须是路径数组。' });
  }
  if (!Array.isArray(result.changed_files)) {
    findings.push({ field: 'changed_files', message: 'changed_files 必须是路径数组。' });
  }
  const snapshot = (task.stage_execution || {}).write_snapshot;
  if (!validStageWriteSnapshot(snapshot, authorized)) {
    findings.push({ field: 'stage_execution.write_snapshot', message: 'long_write 活动阶段缺少可信的启动写集快照。' });
  }
  if (findings.length > 0) return blocked('blocked_result_write_set_violation', findings);

  // The expected result packet is the workflow's receipt, not an author or
  // module artifact. Hosts often include it in their raw write log, so remove
  // it before comparing declared creative writes with the stage snapshot.
  const receiptPath = normalizeWriteSetPath((task.stage_execution || {}).expected_result_packet);
  const withoutReceipt = (values) => normalizedUniquePaths(values).filter((file) => file !== receiptPath);
  const declared = withoutReceipt(result.result_write_set);
  const changed = withoutReceipt(result.changed_files);
  const actual = actualStageFileChanges(projectRoot, snapshot);
  const invalidDeclared = declared.filter((file) => !file || !authorized.some((entry) => writeSetEntryAllows(entry, file)));
  const invalidChanged = changed.filter((file) => !file
    || !authorized.some((entry) => writeSetEntryAllows(entry, file)));
  const invalidActual = actual.filter((file) => !authorized.some((entry) => writeSetEntryAllows(entry, file)));
  const declarationsMatchActual = sameContractValue(declared, actual) && sameContractValue(changed, actual);
  if (invalidDeclared.length > 0 || invalidChanged.length > 0 || invalidActual.length > 0 || !declarationsMatchActual) {
    return blocked('blocked_result_write_set_violation', [{
      field: invalidDeclared.length > 0 ? 'result_write_set' : invalidChanged.length > 0 ? 'changed_files' : 'actual_changed_files',
      message: 'result_write_set、changed_files 与阶段实际文件变更必须完全一致，且全部位于授权写集。',
      unauthorized_result_write_set: invalidDeclared,
      unauthorized_changed_files: invalidChanged,
      unauthorized_actual_changes: invalidActual,
      actual_changed_files: actual,
      declared_result_write_set: declared,
      declared_changed_files: changed,
      authorized_write_set: authorized,
    }]);
  }
  return null;
}

function captureStageWriteSnapshot(projectRoot, task, expectedResultPacket) {
  const authorized = ((task.stage_execution || {}).write_set || []).map(normalizeWriteSetPath);
  const excludedPaths = normalizedUniquePaths([
    // Runner-owned observability/context artifacts are written after a stage
    // starts. They must never be mistaken for the author's stage write set.
    '.novel-assistant/evaluation-prompts',
    '追踪/context-pack',
    '追踪/workflow/.workflow.lock',
    '追踪/workflow/current-task.json',
    '追踪/workflow/current-task.md',
    '追踪/workflow/history.jsonl',
    '追踪/workflow/entry-guard.json',
    '追踪/workflow/session-registry.json',
    '追踪/workflow/task-family-index.json',
    '追踪/workflow/families',
    '追踪/workflow/sessions',
    '追踪/workflow/token-cost-ledger.jsonl',
    '追踪/workflow/token-cost-summary.json',
    `${task.task_dir}/task.json`,
    `${task.task_dir}/journal.jsonl`,
    `${task.task_dir}/rpd.md`,
    `${task.task_dir}/context.jsonl`,
    `${task.task_dir}/verify.jsonl`,
    `${task.task_dir}/canonical-write-baseline.json`,
    `${task.task_dir}/context-packets`,
    `${task.task_dir}/runner-events`,
    `${task.task_dir}/runner-packets`,
    `${task.task_dir}/runner-recovery`,
    // Stage-local diagnostics are workflow-owned evidence, not creative
    // assets. They must not be reported as formal stage writes.
    `${task.task_dir}/work`,
    `${task.task_dir}/memory-projection`,
    `${task.task_dir}/memory-quarantine`,
    expectedResultPacket,
  ]);
  return {
    version: 1,
    captured_at: new Date().toISOString(),
    authorized_write_set: authorized,
    excluded_paths: excludedPaths,
    files: snapshotProjectFiles(projectRoot, excludedPaths),
  };
}

function validStageWriteSnapshot(snapshot, authorized) {
  return Boolean(snapshot && snapshot.version === 1
    && Array.isArray(snapshot.authorized_write_set)
    && sameContractValue(snapshot.authorized_write_set, authorized.map(normalizeWriteSetPath))
    && Array.isArray(snapshot.excluded_paths)
    && snapshot.files && typeof snapshot.files === 'object' && !Array.isArray(snapshot.files));
}

function actualStageFileChanges(projectRoot, snapshot) {
  const before = snapshot.files;
  const after = snapshotProjectFiles(projectRoot, snapshot.excluded_paths);
  return Array.from(new Set([...Object.keys(before), ...Object.keys(after)]))
    .filter(file => before[file] !== after[file])
    .sort();
}

function snapshotProjectFiles(projectRoot, excludedPaths) {
  const root = path.resolve(projectRoot);
  const excluded = excludedPaths.map(normalizeWriteSetPath).filter(Boolean);
  const files = {};
  const visit = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const absolute = path.join(dir, entry.name);
      const relative = rel(root, absolute);
      const entryStat = fs.lstatSync(absolute);
      if (entryStat.isSymbolicLink()) {
        throw new Error(`project tree contains symbolic link: ${relative}`);
      }
      if (relative === '.git' || relative.startsWith('.git/')) continue;
      if (excluded.some(item => relative === item || relative.startsWith(`${item}/`))) continue;
      if (entryStat.isDirectory()) visit(absolute);
      else if (entryStat.isFile()) files[relative] = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex')}`;
    }
  };
  visit(root);
  return files;
}

function validateLongformProjectTreeSymlinks(projectRoot) {
  const inspection = inspectProjectTreeSymlinks(projectRoot);
  if (inspection.error) {
    return blocked('blocked_longform_project_symlink', [{
      field: 'project_tree',
      message: 'long_write 写集快照与验收前必须完整检查项目树；无法安全检查符号链接时不能继续。',
      error: inspection.error,
    }]);
  }
  if (inspection.symlinks.length === 0) return null;
  return blocked('blocked_longform_project_symlink', inspection.symlinks.map((file) => ({
    field: 'project_tree_symlink',
    path: file,
    message: 'long_write 写集快照与验收不允许项目树中存在符号链接，以免写入跟随至项目外。',
  })));
}

function inspectProjectTreeSymlinks(projectRoot) {
  const root = path.resolve(projectRoot);
  const symlinks = [];
  try {
    if (fs.lstatSync(root).isSymbolicLink()) return { symlinks: ['.'], error: '' };
    const visit = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const absolute = path.join(dir, entry.name);
        const relative = rel(root, absolute);
        const entryStat = fs.lstatSync(absolute);
        if (entryStat.isSymbolicLink()) {
          symlinks.push(relative);
        } else if (relative === '.git' || relative.startsWith('.git/')) {
          continue;
        } else if (entryStat.isDirectory()) {
          visit(absolute);
        }
      }
    };
    visit(root);
    return { symlinks: symlinks.sort(), error: '' };
  } catch (error) {
    return { symlinks, error: String(error && error.message ? error.message : error) };
  }
}

function normalizedUniquePaths(values) {
  return Array.from(new Set((values || []).map(normalizeWriteSetPath))).sort();
}

function normalizeWriteSetPath(value) {
  const raw = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//, '');
  if (!raw || path.isAbsolute(raw) || raw.split('/').includes('..')) return '';
  return raw.replace(/\/{2,}/g, '/');
}

function writeSetEntryAllows(entry, file) {
  const rule = normalizeWriteSetPath(entry);
  if (!rule) return false;
  if (rule.endsWith('/**')) {
    const prefix = rule.slice(0, -3);
    return file === prefix || file.startsWith(`${prefix}/`);
  }
  return file === rule;
}

function validateLongformResultContract(task, result) {
  if (task.workflow_type !== 'long_write') return null;
  const tpl = templates().long_write;
  const graph = task.lifecycle_graph || {};
  const lifecycleNodeId = String(graph.current_node || '');
  const stageDef = findStage(tpl, lifecycleNodeId);
  const graphNode = (graph.nodes || []).find((node) => node && node.id === lifecycleNodeId);
  const findings = [];
  if (!stageDef || lifecycleNodeId !== String(task.current_stage || '')) {
    findings.push({
      field: 'lifecycle_graph.current_node',
      message: 'long_write 活动生命周期节点必须同时存在于受支持模板并匹配 current_stage。',
      expected: task.current_stage,
      actual: lifecycleNodeId,
    });
  }
  if (!graphNode || (stageDef && (graphNode.owner_module !== stageDef.owner_module
    || !sameContractValue(graphNode.asset_target, stageDef.asset_target)
    || !sameContractValue(graphNode.review_requirement, stageDef.review_requirement)))) {
    findings.push({
      field: `lifecycle_graph.nodes.${lifecycleNodeId || 'current'}`,
      message: 'long_write 活动 lifecycle_graph 节点必须匹配不可变模板合同。',
    });
  }
  if (!stageDef) return blocked('blocked_longform_result_contract_mismatch', findings);
  const expected = {
    owner_module: stageDef.owner_module || '',
    lifecycle_node: stageDef.lifecycle_node || stageDef.stage_id,
    asset_target: stageDef.asset_target || {},
    review_requirement: stageDef.review_requirement || {},
  };
  for (const field of Object.keys(expected)) {
    if (result[field] === undefined || result[field] === null) {
      findings.push({ field, message: `long_write v2 result packet 缺少活动生命周期字段 ${field}。` });
    } else if (!sameContractValue(result[field], expected[field])) {
      findings.push({ field, message: `long_write v2 result packet ${field} 与活动生命周期节点 ${task.current_stage} 不一致。`, expected: expected[field], actual: result[field] });
    }
  }
  const transitionRequest = validateLifecycleTransitionRequest(stageDef, lifecycleNodeId, result);
  if (transitionRequest.status !== 'valid') {
    findings.push({
      field: 'lifecycle_transition_request',
      message: 'long_write 生命周期请求必须停留在当前节点、进入 allowed_next，或按审阅合同回退；禁止跨级跳转。',
      details: transitionRequest,
    });
  } else if (transitionRequest.requested_next && transitionRequest.requested_next !== lifecycleNodeId) {
    result.next_stage_id = transitionRequest.requested_next;
  }
  return findings.length > 0 ? blocked('blocked_longform_result_contract_mismatch', findings) : null;
}

function validateLongformReviewAcceptance(task, result, stageDef) {
  const requirement = (stageDef || {}).review_requirement || {};
  if (task.workflow_type !== 'long_write' || requirement.required !== true) return null;
  const stepStatus = String(result.step_status || '').trim().toLowerCase();
  const reviewResult = String(result.verification_result || '').trim().toLowerCase();
  if (stepStatus === 'completed' && LONG_WRITE_ACCEPTED_REVIEW_RESULTS.has(reviewResult)) return null;
  const explicitFailure = ['blocked', 'failed'].includes(stepStatus)
    || (stepStatus === 'completed' && (WORKFLOW_TRANSITIONS.normalizeBlockingFindings(result).length > 0
      || /(blocking|blocked|fail|failed|reject|rejected|hard_blocker|error)/.test(reviewResult)));
  if (explicitFailure) return null;
  return blocked('blocked_longform_review_acceptance_required', [{
    field: 'verification_result',
    message: `必需审阅节点 ${task.current_stage} 只有 completed 且明确 accepted/approved/pass 的结果才能解锁下游；skipped、空值和不确定结果必须停留在当前审阅节点。`,
    step_status: stepStatus,
    review_result: reviewResult,
  }]);
}

function sameContractValue(actual, expected) {
  if (actual && typeof actual === 'object') return JSON.stringify(actual) === JSON.stringify(expected);
  return String(actual) === String(expected);
}

function validateEvidenceScanReceipt(task, result, projectRoot) {
  if (task.workflow_type !== 'review_repair' || task.current_stage !== 'evidence_scan') return null;
  const evidencePolicy = task.review_evidence_policy
    || reviewEvidencePolicy(task.review_target || resolveReviewTarget({ text: task.user_goal, scope: task.scope }, {}));
  if (evidencePolicy.mode === 'asset_dependency_closure') {
    const receipt = validateAssetDependencyEvidenceReceipt(evidencePolicy, result.evidence, { project_root: projectRoot });
    if (!receipt.valid) {
      return blocked('blocked_review_asset_dependency_evidence_incomplete', [{
        field: 'evidence',
        message: '资产审阅回执必须覆盖目标资产及其全部上游依赖，并提供来源引用。',
        missing_assets: receipt.missing_assets,
      }]);
    }
  } else {
    const expectedScope = String(((task.stage_execution || {}).batch_scope) || '');
    if (!expectedScope || String(result.batch_scope || '') !== expectedScope) {
      return blocked('blocked_review_batch_scope_mismatch', 'evidence_scan result packet 必须声明当前批次的精确范围。');
    }
    const expectedRange = parseNumericScope(expectedScope);
    const coverage = result.fullRangeCoverage;
    const protocolFindings = [];
    if (result.protocolVersion !== REVIEW_EVIDENCE_PROTOCOL_VERSION) {
      protocolFindings.push({ field: 'protocolVersion', message: `evidence_scan result packet 必须使用协议 ${REVIEW_EVIDENCE_PROTOCOL_VERSION}。` });
    }
    if (!/^[0-9a-f]{64}$/.test(String(result.sourceDigest || ''))) {
      protocolFindings.push({ field: 'sourceDigest', message: 'evidence_scan result packet 必须携带有效来源摘要。' });
    }
    const expectedCount = expectedRange ? expectedRange.end - expectedRange.start + 1 : 0;
    if (!coverage || !expectedRange
      || Number(coverage.start) !== expectedRange.start
      || Number(coverage.end) !== expectedRange.end
      || Number(coverage.coveredChapters) !== expectedCount
      || coverage.complete !== true) {
      protocolFindings.push({ field: 'fullRangeCoverage', message: 'evidence_scan result packet 必须证明当前批次完整逐章覆盖。' });
    }
    if (protocolFindings.length === 0) {
      const currentEvidence = buildEvidenceMap(projectRoot, expectedRange, {
        scriptDir: __dirname,
        skipChapterChecks: true,
        skipPriorReports: true,
      });
      const currentDigest = buildSourceIdentity(currentEvidence).digest;
      if (currentEvidence.status !== 'ok' || result.sourceDigest !== currentDigest) {
        protocolFindings.push({ field: 'sourceDigest', message: 'evidence_scan result packet 的来源摘要与当前批次正文不一致。' });
      }
    }
    if (protocolFindings.length > 0) {
      return blocked('blocked_review_evidence_protocol_incompatible', protocolFindings);
    }
  }
  const arrayWriteDeclarationFields = ['changed_files', 'created_files', 'write_actions', 'canonical_writes'];
  const invalidFields = arrayWriteDeclarationFields.filter((field) => result[field] !== undefined
    && result[field] !== null
    && !Array.isArray(result[field]));
  if (invalidFields.length > 0) {
    return blocked('blocked_review_evidence_scan_write_declaration_invalid', invalidFields.map((field) => ({
      field,
      message: 'evidence_scan 写入声明必须是数组；类型不可信时不能推进批次。',
    })));
  }
  const changedFiles = (result.changed_files || []).filter(Boolean);
  const createdFiles = (result.created_files || []).filter(Boolean);
  const writeActions = result.write_actions || [];
  const canonicalWrites = result.canonical_writes || [];
  const writeDeclaration = changedFiles.length > 0
    || createdFiles.length > 0
    || Boolean(result.chapter_commit)
    || Boolean(result.write_intent)
    || writeActions.length > 0
    || canonicalWrites.length > 0;
  if (writeDeclaration) {
    return blocked('blocked_review_evidence_scan_read_only', 'evidence_scan 是只读审阅，不能声明正文或 canonical 资产写入。');
  }
  return null;
}

function blockedLegacyReviewPlan(task) {
  return { schemaVersion: SCHEMA_VERSION, ...legacyReadOnlyBlock(task) };
}

function validateV2ExecutionBinding(task, result, projectRoot, resultFile, taskTemplate) {
  const tpl = taskTemplate;
  const stageDef = findStage(tpl, task.current_stage) || {};
  const execution = task.stage_execution || {};
  if (execution.status !== 'running') {
    return stageDef.requires_user_confirm
      ? blocked('blocked_confirmation_required', '当前确认阶段没有持久化的 running stage_execution 与确认 token。')
      : blocked('blocked_stage_execution_required', 'v2 result packet 只能应用到当前 running stage_execution。');
  }

  const idFindings = [];
  if (!execution.stage_id || execution.stage_id !== task.current_stage || result.stage_id !== execution.stage_id) {
    idFindings.push({ field: 'stage_execution.stage_id', message: 'v2 result packet stage_id 必须匹配当前 running stage_execution。' });
  }
  if (!execution.step_id || execution.step_id !== task.current_step || result.step_id !== execution.step_id) {
    idFindings.push({ field: 'stage_execution.step_id', message: 'v2 result packet step_id 必须匹配当前 running stage_execution。' });
  }
  if (idFindings.length > 0) return blocked('blocked_stage_execution_mismatch', idFindings);

  const expectedRel = String(execution.expected_result_packet || '');
  const expectedAbs = resolveSafeProjectFile(projectRoot, expectedRel);
  const actualAbs = resolveSafeProjectFile(projectRoot, resultFile);
  const declaredAbs = resolveSafeProjectFile(projectRoot, String(result.result_packet_path || ''));
  if (!expectedRel || !expectedAbs || !actualAbs || !declaredAbs) {
    return blocked('blocked_result_packet_path_unsafe', 'v2 expected_result_packet、实际 packet 和声明路径都必须位于项目目录内。');
  }
  if (expectedAbs !== actualAbs || expectedAbs !== declaredAbs) {
    return blocked('blocked_result_packet_path_mismatch', '只能应用当前 stage_execution.expected_result_packet 指向的唯一 packet。');
  }
  const checkpointExpected = String((((task.runtime_guard || {}).checkpoint_policy || {}).expected_result_packet) || '');
  if (checkpointExpected && resolveSafeProjectFile(projectRoot, checkpointExpected) !== expectedAbs) {
    return blocked('blocked_result_packet_path_mismatch', 'checkpoint_policy.expected_result_packet 与 running stage_execution 不一致。');
  }

  if (stageDef.requires_user_confirm && !resultPreviouslyValidatedBeforeAudit(task, result, resultFile, projectRoot)) {
    const confirmationValidation = validateConfirmationContext(task, execution);
    if (confirmationValidation) return confirmationValidation;
  }
  return null;
}

function resultPreviouslyValidatedBeforeAudit(task, result, resultFile, projectRoot) {
  const block = (task || {}).canonical_write_audit_block || {};
  // pre_apply blocks are created only after validateResultAgainstTask succeeds.
  // Older tasks predate the explicit marker, so absence remains compatible;
  // an explicit false value is never trusted.
  if (block.result_packet_validated_before_audit === false || String(block.phase || '') !== 'pre_apply') return false;
  if (!resultFile || !fs.existsSync(resultFile)) return false;
  const normalizedFile = String(resultFile || '').replace(/\\/g, '/');
  const expectedSuffix = `/${String(block.result_packet_path || '').replace(/\\/g, '/').replace(/^\/+/, '')}`;
  if (!normalizedFile.endsWith(expectedSuffix)) return false;
  if (String(block.result_packet_hash || '') === hashFile(resultFile)) return true;

  // Compatibility for result packets rewritten by older non-idempotent
  // finalizers while recovering the same accepted stage attempt.
  const commitId = String((((result || {}).chapter_commit || {}).accepted_commit_id)
    || ((((result || {}).evidence || [])[0] || {}).commit_id)
    || '');
  if (!commitId) return false;
  const commitFile = path.join(path.resolve(projectRoot), '追踪', 'story-system', 'commits', `${commitId}.json`);
  if (!fs.existsSync(commitFile)) return false;
  const commit = readJson(commitFile) || {};
  const provenance = commit.provenance || {};
  return commit.status === 'accepted'
    && String(commit.workflow_id || '') === String(task.workflow_id || '')
    && String(provenance.stage_attempt_id || '') === String(((task || {}).stage_execution || {}).stage_attempt_id || '');
}

function validateConfirmationContext(task, execution) {
  const confirmation = execution.confirmation_context || {};
  const selection = task.last_selection || {};
  const pending = task.pending_action || {};
  const expiresAt = Date.parse(String(confirmation.expires_at || ''));
  const matches = Boolean(confirmation.confirmation_token)
    && confirmation.status === 'confirmed'
    && confirmation.confirmation_token === execution.confirmation_token
    && confirmation.confirmation_token === selection.confirmation_token
    && confirmation.workflow_id === task.workflow_id
    && confirmation.workflow_type === task.workflow_type
    && confirmation.stage_id === execution.stage_id
    && confirmation.step_id === execution.step_id
    && confirmation.selection_id === pending.id
    && confirmation.selected_number === execution.selected_number
    && confirmation.selected_number === selection.selected_number
    && confirmation.selected_action_id === execution.action_id
    && confirmation.selected_action_id === selection.action_id
    && confirmation.visible_choice_hash === pending.visible_choice_hash
    && confirmation.visible_choice_hash === selection.visible_choice_hash
    && pending.status === 'resolved'
    && selection.requires_user_confirm === true
    && Number.isFinite(expiresAt)
    && expiresAt > Date.now();
  if (!matches) {
    return blocked('blocked_confirmation_required', '确认 selection/token 缺失、已过期或与当前 workflow/stage 不匹配，请重新显示并确认当前操作。');
  }
  if (task.workflow_type === 'cover' && !['generate', 'overwrite'].includes(confirmation.operation)) {
    return blocked('blocked_confirmation_required', '封面确认必须明确是生成新封面还是覆盖现有封面。');
  }
  return null;
}

function validateChapterCommit(projectRoot, task, result) {
  if (result.step_status !== 'completed') return null;
  const isLongformCommit = task.workflow_type === 'long_write' && task.current_stage === 'chapter_commit';
  const strictCanonicalTargets = strictCanonicalResultTargets(projectRoot, result);
  if (strictCanonicalTargets.error) return strictCanonicalTargets.error;
  const requiresTransaction = isLongformCommit || strictCanonicalTargets.targets.length > 0;
  if (!requiresTransaction) return null;
  const chapterCommit = result.chapter_commit;
  if (!chapterCommit || typeof chapterCommit !== 'object') {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: strictCanonicalTargets.targets.length > 0 ? 'blocked_canonical_transaction_required' : 'blocked_chapter_commit_missing',
      findings: [{
        field: 'chapter_commit',
        message: strictCanonicalTargets.targets.length > 0
          ? '严格模式下审阅修复修改正式资产前必须提供 accepted chapter commit。'
          : '长篇章节提交节点完成前必须提供 accepted chapter commit。',
      }],
    };
  }
  if (chapterCommit.mode === 'legacy_nontransactional') {
    if (strictCanonicalTargets.targets.length > 0) {
      return {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_canonical_transaction_required',
        findings: [{ field: 'chapter_commit.mode', message: '严格模式下正式资产修复不能使用 legacy_nontransactional。' }],
      };
    }
    const changedFiles = Array.isArray(result.changed_files) ? result.changed_files.filter(Boolean) : [];
    if (!changedFiles.length || !chapterCommit.legacy_reason || chapterCommit.risk_acknowledged !== true) {
      return {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_chapter_commit_invalid',
        findings: [{ field: 'chapter_commit', message: 'legacy_nontransactional 必须列出变更文件、兼容原因并显式确认风险。' }],
      };
    }
    return null;
  }
  if (chapterCommit.mode !== 'transactional') {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit.mode', message: 'chapter_commit.mode 必须是 transactional 或 legacy_nontransactional。' }],
    };
  }

  const commitId = String(chapterCommit.accepted_commit_id || '');
  const commitRel = String(chapterCommit.commit_file || '');
  const stagedArtifacts = Array.isArray(chapterCommit.staged_artifacts) ? chapterCommit.staged_artifacts.filter(Boolean) : [];
  if (!commitId || !commitRel || !stagedArtifacts.length) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit', message: 'transactional chapter_commit 缺少 accepted_commit_id、commit_file 或 staged_artifacts。' }],
    };
  }
  const commitFile = resolveInsideProject(projectRoot, commitRel);
  if (!commitFile || !fs.existsSync(commitFile) || !fs.statSync(commitFile).isFile()) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit.commit_file', message: 'accepted commit 文件不存在或越出书目目录。' }],
    };
  }
  const commit = readJson(commitFile);
  if (!commit || commit.__error || commit.status !== 'accepted' || commit.commit_id !== commitId || !Array.isArray(commit.artifacts) || commit.artifacts.length === 0) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit.accepted_commit_id', message: 'commit 文件与 result packet 不一致，或不是有效 accepted commit。' }],
    };
  }
  const driftedArtifact = commit.artifacts.find((artifact) => {
    const target = resolveInsideProject(projectRoot, String((artifact && artifact.target) || ''));
    const expected = String((artifact && artifact.after_hash) || '');
    if (!target || !/^sha256:[a-f0-9]{64}$/i.test(expected) || !fs.existsSync(target) || !fs.statSync(target).isFile()) return true;
    const actual = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')}`;
    return actual !== expected.toLowerCase();
  });
  if (driftedArtifact) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit.artifacts', message: `accepted commit 制品已缺失或发生漂移：${driftedArtifact.target || 'unknown'}` }],
    };
  }
  if (commit.workflow_id && commit.workflow_id !== task.workflow_id) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_commit_invalid',
      findings: [{ field: 'chapter_commit.workflow_id', message: 'accepted commit 不属于当前 workflow。' }],
    };
  }
  const committedTargets = new Set(commit.artifacts.map((artifact) => String((artifact && artifact.target) || '')));
  const missingCanonicalTarget = strictCanonicalTargets.targets.find((target) => !committedTargets.has(target));
  if (missingCanonicalTarget) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_canonical_transaction_target_mismatch',
      findings: [{ field: 'chapter_commit.artifacts', message: `accepted commit 未覆盖正式资产：${missingCanonicalTarget}` }],
    };
  }
  const projectionStatus = String(chapterCommit.projection_status || '');
  if (!['projection_current', 'projection_not_required'].includes(projectionStatus) || chapterCommit.projection_debt === true) {
    return {
      schemaVersion: SCHEMA_VERSION,
      status: 'blocked_chapter_projection_debt',
      findings: [{ field: 'chapter_commit.projection_status', message: '记忆投影债务未关闭，必须 replay 后才能进入下一章。' }],
    };
  }
  return null;
}

function strictCanonicalResultTargets(projectRoot, result) {
  const changedFiles = Array.isArray(result.changed_files) ? result.changed_files.filter(Boolean) : [];
  if (!changedFiles.length) return { targets: [], error: null };
  let policy;
  let targets;
  try {
    policy = loadCanonicalWritePolicy(projectRoot);
    if (policy.mode !== 'strict') return { targets: [], error: null };
    targets = normalizeTargets(projectRoot, changedFiles).filter(isCanonicalTarget);
  } catch (error) {
    return {
      targets: [],
      error: {
        schemaVersion: SCHEMA_VERSION,
        status: error && error.code ? error.code : 'blocked_canonical_transaction_invalid',
        findings: [{ field: 'changed_files', message: String(error && error.message ? error.message : error) }],
      },
    };
  }
  return { targets, error: null };
}

function resolveInsideProject(projectRoot, relativePath) {
  const root = path.resolve(projectRoot);
  const file = path.resolve(root, relativePath);
  if (file === root || !file.startsWith(`${root}${path.sep}`)) return '';
  return file;
}

function resolveSafeProjectFile(projectRoot, filePath) {
  if (!filePath) return '';
  const root = path.resolve(projectRoot);
  const file = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(root, filePath);
  if (file === root || !file.startsWith(`${root}${path.sep}`)) return '';
  try {
    const realRoot = fs.realpathSync(root);
    let existing = file;
    while (!fs.existsSync(existing) && existing !== root) existing = path.dirname(existing);
    const realExisting = fs.realpathSync(existing);
    if (realExisting !== realRoot && !realExisting.startsWith(`${realRoot}${path.sep}`)) return '';
  } catch (_) {
    return '';
  }
  return file;
}

function advanceTask(task, result, projectRoot, taskTemplate) {
  const tpl = taskTemplate;
  const machine = normalizeMachine(task, tpl);
  const now = new Date().toISOString();
  const stageId = result.stage_id;
  const transition = WORKFLOW_TRANSITIONS.resolveStageTransition(tpl, machine, stageId, result, task, projectRoot);
  if (transition.complete_current_stage && !machine.completed_stages.includes(stageId)) machine.completed_stages.push(stageId);
  if (transition.blocked && !transition.complete_current_stage) {
    machine.completed_stages = machine.completed_stages.filter((item) => item !== stageId);
  }
  machine.remaining_stages = transition.remaining_stages;
  if (Array.isArray(transition.invalidated_nodes) && transition.invalidated_nodes.length > 0) {
    machine.completed_stages = machine.completed_stages.filter((item) => !transition.invalidated_nodes.includes(item));
  }
  let nextStageId = transition.next_stage_id || '';
  if (!nextStageId) {
    const debtResumeStage = completionDebtResumeStage(task, tpl);
    if (debtResumeStage) {
      nextStageId = debtResumeStage;
      transition.remaining_stages = [
        debtResumeStage,
        ...(Array.isArray(transition.remaining_stages) ? transition.remaining_stages : [])
          .filter((item) => item !== debtResumeStage),
      ];
      transition.reason = 'workflow_completion_debt_requires_resume';
    }
  }
  task.current_stage = nextStageId || stageId;
  task.current_step = nextStageId || stageId;
  task.status = nextStageId ? 'running' : 'completed';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.updated_at = now;
  if (task.workflow_type === 'long_write') {
    task.lifecycle_graph = advanceLongformLifecycleGraph(task, tpl, stageId, nextStageId, transition, result);
  }
  task.unit_lifecycle = advanceUnitLifecycleState(task.unit_lifecycle, tpl, nextStageId ? findStage(tpl, nextStageId) : null, result, now, {
    completeCurrentStage: transition.complete_current_stage,
  });
  if (isShortWritingWorkflow(task) && ['section_plan_lock', 'short_structure_impact_audit', 'hook_retention_gate', 'hook_value_gate', 'full_story_assembly', 'full_story_review', 'short_deslop', 'deslop', 'final_check'].includes(nextStageId)) {
    synchronizeShortWholeStoryScope(task, nextStageId);
  }
  if (!nextStageId) {
    task.lifecycle.status = 'completed';
    task.lifecycle.completed_at = now;
  }
  machine.last_transition = transition.reason || (nextStageId ? 'stage_completed' : 'workflow_completed');
  machine.last_result_packet = result.result_packet_path || '';
  machine.last_blocking_findings = transition.blocked ? WORKFLOW_TRANSITIONS.normalizeBlockingFindings(result) : [];
  machine.next_stop_reason = nextStageId ? nextStopReason(task, findStage(tpl, nextStageId)) : 'completed';
  machine.allowed_actions = nextStageId ? ['continue_next_stage', 'pause'] : [];
  task.machine = machine;
  const trustedResult = String(result.result_packet_path || trustedArtifactFromResult(result) || '');
  task.stage_execution = {
    ...(task.stage_execution || {}),
    status: 'completed',
    completed_at: now,
    result_packet: trustedResult,
  };
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.heartbeat = {
    ...(task.runtime_guard.heartbeat || {}),
    updated_at: now,
    latest_trusted_artifact: trustedResult || ((task.runtime_guard.heartbeat || {}).latest_trusted_artifact || ''),
    current_batch: nextStageId || stageId,
    workflow_id: task.workflow_id || '',
  };
  task.runtime_guard.checkpoint_policy = {
    ...(task.runtime_guard.checkpoint_policy || {}),
    resume_from: nextStageId || stageId,
    expected_result_packet: '',
  };
  task.recommended_next = normalizeRecommendations(result.next_recommendation);
  if (stageId === 'section_repair_loop'
    && String(result.step_status || '') === 'completed'
    && String(((task.short_feedback_impact || {}).impact_level) || '') === 'expression_only') {
    resolveShortFeedback(projectRoot, task, result);
    task.last_resolved_feedback = {
      ...(task.pending_feedback || {}),
      resolved_at: now,
      result_packet_path: String(result.result_packet_path || ''),
    };
    task.pending_feedback = null;
  }
  if (stageId === 'feedback_apply_patch'
    && String(result.step_status || '') === 'completed'
    && task.pending_feedback) {
    resolveShortFeedback(projectRoot, task, result);
    task.last_resolved_feedback = {
      ...task.pending_feedback,
      resolved_at: now,
      result_packet_path: String(result.result_packet_path || ''),
      resolution: 'planning_patch_applied_downstream_revalidation_required',
    };
    task.pending_feedback = null;
  }
  task.pending_action = nextStageId
    ? transition.reason === 'short_quality_single_candidate_ready' && nextStageId === 'section_accept_anchor'
      ? buildShortSectionDecisionPendingAction(tpl, task)
      : isShortWritingWorkflow(task) && ['draft_first_section', 'draft_section', 'draft_next_section'].includes(nextStageId)
        ? buildShortDraftPendingAction(findStage(tpl, nextStageId), task)
        : buildPendingAction(tpl, findStage(tpl, nextStageId))
    : buildCompletionPendingAction(task, task.recommended_next);
  return task;
}

function completionDebtResumeStage(task, tpl) {
  const stageIds = new Set(((tpl || {}).stages || []).map((stage) => String(stage.stage_id || '')));
  const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : null;
  if (acceptedPlan
      && ['pending', 'accepted_pending_projection'].includes(String(acceptedPlan.projection_status || acceptedPlan.status || ''))
      && stageIds.has('feedback_apply_patch')) {
    return 'feedback_apply_patch';
  }
  const queue = activeShortFeedbackRevision(task);
  if (queue && stageIds.has('next_section_brief')) return 'next_section_brief';
  return '';
}

// Transition rules live in workflow-transition-service.js.

function normalizeTask(task) {
  const tpl = templates()[task.workflow_type];
  return { ...task, machine: normalizeMachine(task, tpl) };
}

function normalizeMachine(task, tpl) {
  const stages = tpl ? tpl.stages.map((item) => item.stage_id) : [];
  const machine = task.machine || {};
  const completed = Array.isArray(machine.completed_stages) ? machine.completed_stages.slice() : [];
  let remaining = Array.isArray(machine.remaining_stages) ? machine.remaining_stages.slice() : [];
  if (remaining.length === 0 && stages.length > 0) {
    const currentIndex = Math.max(0, stages.indexOf(task.current_stage || stages[0]));
    remaining = stages.slice(currentIndex).filter((stageId) => !completed.includes(stageId));
  }
  return {
    template_version: machine.template_version || SCHEMA_VERSION,
    completed_stages: completed,
    remaining_stages: remaining,
    allowed_actions: Array.isArray(machine.allowed_actions) && machine.allowed_actions.length > 0 ? machine.allowed_actions : ['continue_next_stage', 'pause'],
    last_transition: machine.last_transition || 'normalized',
    last_execution_event: machine.last_execution_event || '',
    last_result_packet: machine.last_result_packet || '',
    next_stop_reason: machine.next_stop_reason || nextStopReason(task, findStage(tpl, task.current_stage)),
  };
}

function normalizeLifecycle(task) {
  const now = new Date().toISOString();
  const lifecycle = task.lifecycle || {};
  return {
    status: lifecycle.status || (task.status === 'completed' ? 'completed' : 'active'),
    started_at: lifecycle.started_at || task.created_at || now,
    updated_at: lifecycle.updated_at || task.updated_at || now,
    completed_at: lifecycle.completed_at || '',
    user_goal: lifecycle.user_goal || task.user_goal || '',
    scope: lifecycle.scope || task.scope || '',
    previous_workflow_id: lifecycle.previous_workflow_id || '',
    switch_reason: lifecycle.switch_reason || '',
  };
}

function longformLifecycleMigrationBlock(task) {
  if (!task || task.workflow_type !== 'long_write') return null;
  const tpl = templates().long_write;
  const graph = task.lifecycle_graph;
  const findings = [];
  const expectedIds = tpl.stages.map((stageDef) => stageDef.stage_id);
  const expectedIdSet = new Set(expectedIds);
  if (!graph || typeof graph !== 'object' || Array.isArray(graph)) {
    findings.push({ field: 'lifecycle_graph', message: 'long_write task 缺少作品生命周期图。' });
  } else {
    if (graph.version !== SCHEMA_VERSION) findings.push({ field: 'lifecycle_graph.version', message: `作品生命周期图版本必须是 ${SCHEMA_VERSION}。` });
    if (!expectedIdSet.has(String(graph.current_node || '')) || graph.current_node !== task.current_stage) {
      findings.push({ field: 'lifecycle_graph.current_node', message: '作品生命周期当前节点必须与 current_stage 一致。' });
    }
    const currentStage = findStage(tpl, task.current_stage);
    if (!currentStage || !sameContractValue(graph.asset_target, currentStage.asset_target)) {
      findings.push({ field: 'lifecycle_graph.asset_target', message: '作品生命周期资产目标与当前节点不一致。' });
    }
    for (const field of ['completed_nodes', 'invalidated_nodes']) {
      if (!Array.isArray(graph[field]) || graph[field].some((id) => !expectedIdSet.has(id))) {
        findings.push({ field: `lifecycle_graph.${field}`, message: `${field} 必须只包含受支持的作品生命周期节点。` });
      }
    }
    const nodes = Array.isArray(graph.nodes) ? graph.nodes : [];
    const nodeById = new Map(nodes.map((node) => [node && node.id, node]));
    if (nodes.length !== expectedIds.length || expectedIds.some((id) => !nodeById.has(id))) {
      findings.push({ field: 'lifecycle_graph.nodes', message: '作品生命周期图必须包含完整且唯一的受支持节点集合。' });
    } else {
      for (const stageDef of tpl.stages) {
        const node = nodeById.get(stageDef.stage_id) || {};
        if (node.owner_module !== stageDef.owner_module
          || !sameContractValue(node.asset_target, stageDef.asset_target)
          || !sameContractValue(node.review_requirement, stageDef.review_requirement)
          || !LONG_WRITE_NODE_STATUSES.has(String(node.status || ''))) {
          findings.push({ field: `lifecycle_graph.nodes.${stageDef.stage_id}`, message: '生命周期节点模块、资产目标或审阅要求与受支持模板不一致。' });
        }
      }
    }
    const reviewResults = graph.review_results;
    if (!reviewResults || typeof reviewResults !== 'object' || Array.isArray(reviewResults)) {
      findings.push({ field: 'lifecycle_graph.review_results', message: '作品生命周期图缺少显式审阅结果台账。' });
    }
  }
  if (findings.length === 0) return null;
  const source = normalizeMigrationSource(task.migration_source || (((task.migration || {}).source) || ''));
  const sourceAlias = source === 'worldwonderer/oh-story-claudecode' ? 'oh-story'
    : source === 'novel-assistant/previous-version' ? 'novel-assistant-previous' : '';
  const options = sourceAlias ? [
    {
      number: 1,
      label: '迁移旧协议并从最早未验收阶段继续（推荐）',
      action: 'migrate_legacy_longform',
      description: '保留旧任务和旧证据，创建当前协议继任任务；不改正文、大纲或设定。',
      execution_command: `node scripts/workflow-legacy-migrate.js --project-root . --source ${sourceAlias} --write --workflow-id ${shellQuote(task.workflow_id)} --json`,
    },
    { number: 2, label: '查看迁移依据与风险', action: 'inspect_migration', description: '只读预演，不写入任务状态。', execution_command: `node scripts/workflow-legacy-migrate.js --project-root . --source ${sourceAlias} --json` },
    { number: 3, label: '暂停并保留旧任务', action: 'pause', description: '保持旧任务可读，不继续执行。' },
    { number: 4, label: '输入其他要求', action: 'free_text', description: '补充迁移来源、范围或新的写作目标。' },
  ] : [
    { number: 1, label: '查看旧任务来源与迁移风险（推荐）', action: 'inspect_migration_source', description: '当前来源不可信，只读检查，不自动迁移。' },
    { number: 2, label: '保持旧任务只读', action: 'keep_read_only', description: '不写入旧任务或创作资产。' },
    { number: 3, label: '暂停并保存', action: 'pause', description: '保留当前状态。' },
    { number: 4, label: '输入其他要求', action: 'free_text', description: '明确这是 oh-story 旧项目或上一版 novel-assistant 项目。' },
  ];
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'blocked_longform_lifecycle_migration_required',
    workflow_id: String(task.workflow_id || ''),
    findings,
    source_status: sourceAlias ? 'supported' : 'unknown',
    options,
    text: `检测到旧版长篇工作流，当前协议不能直接继续。\n\n${options.map(option => `${option.number}. ${option.label}\n   ${option.description}`).join('\n')}\n\n回复数字选择。`,
  };
}

function longformLifecycleProgressBlock(task) {
  if (!task || task.workflow_type !== 'long_write') return null;
  const tpl = templates().long_write;
  const graph = task.lifecycle_graph || {};
  const currentIndex = tpl.stages.findIndex((stageDef) => stageDef.stage_id === graph.current_node);
  if (currentIndex < 0) return null;
  const completed = new Set(graph.completed_nodes || []);
  const nodeById = new Map((graph.nodes || []).map((node) => [node.id, node]));
  const reviewResults = graph.review_results || {};
  for (const stageDef of tpl.stages.slice(0, currentIndex)) {
    const node = nodeById.get(stageDef.stage_id) || {};
    const receipt = reviewResults[stageDef.stage_id] || {};
    const reviewAccepted = ((stageDef.review_requirement || {}).required) !== true
      || (receipt.status === 'accepted'
        && LONG_WRITE_ACCEPTED_REVIEW_RESULTS.has(String(receipt.verification_result || '').toLowerCase()));
    if (!completed.has(stageDef.stage_id) || node.status !== 'accepted' || !reviewAccepted) {
      return {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_longform_lifecycle_incomplete',
        first_missing_node: stageDef.stage_id,
        findings: [{
          field: `lifecycle_graph.nodes.${stageDef.stage_id}`,
          message: `生命周期节点 ${graph.current_node} 的前置节点 ${stageDef.stage_id} 尚未完成并进入 accepted 状态。`,
        }],
      };
    }
  }
  return null;
}

function buildLongformLifecycleGraph(tpl, currentNode) {
  const stages = new Map((tpl.stages || []).map((item) => [item.stage_id, item]));
  const current = stages.get(currentNode) || stages.get('positioning');
  return {
    version: SCHEMA_VERSION,
    current_node: current ? current.stage_id : 'positioning',
    asset_target: current ? { ...current.asset_target } : { kind: 'book', id: 'current-book' },
    completed_nodes: [],
    invalidated_nodes: [],
    review_results: {},
    last_transition_validation: null,
    nodes: LIFECYCLE_NODES.map((node) => {
      const stageDef = stages.get(node.id) || {};
      return {
        ...node,
        owner_module: stageDef.owner_module || '',
        asset_target: { ...(stageDef.asset_target || {}) },
        review_requirement: { ...(stageDef.review_requirement || {}) },
        status: 'missing',
      };
    }),
  };
}

function normalizeLongformLifecycleGraph(task, tpl) {
  const source = task.lifecycle_graph;
  const normalized = buildLongformLifecycleGraph(tpl, source.current_node || task.current_stage || 'positioning');
  normalized.completed_nodes = source.completed_nodes.filter((item) => LIFECYCLE_NODES.some((node) => node.id === item));
  normalized.invalidated_nodes = Array.isArray(source.invalidated_nodes)
    ? source.invalidated_nodes.filter((item) => LIFECYCLE_NODES.some((node) => node.id === item))
    : [];
  normalized.review_results = source.review_results && typeof source.review_results === 'object' && !Array.isArray(source.review_results)
    ? { ...source.review_results }
    : {};
  normalized.last_transition_validation = source.last_transition_validation && typeof source.last_transition_validation === 'object'
    ? { ...source.last_transition_validation }
    : null;
  const sourceNodes = new Map(source.nodes.map((node) => [node.id, node]));
  normalized.nodes = normalized.nodes.map((node) => ({
    ...node,
    status: String((sourceNodes.get(node.id) || {}).status || 'missing'),
  }));
  return normalized;
}

function advanceLongformLifecycleGraph(task, tpl, stageId, nextStageId, transition, result) {
  const graph = normalizeLongformLifecycleGraph(task, tpl);
  const invalidated = new Set(graph.invalidated_nodes);
  const completed = new Set(graph.completed_nodes);
  const reviewResults = { ...(graph.review_results || {}) };
  const nodeStatuses = new Map(graph.nodes.map((node) => [node.id, node.status]));
  if (transition.complete_current_stage) {
    completed.add(stageId);
    invalidated.delete(stageId);
    nodeStatuses.set(stageId, 'accepted');
    const stageDef = findStage(tpl, stageId);
    if ((((stageDef || {}).review_requirement || {}).required) === true) {
      reviewResults[stageId] = {
        status: 'accepted',
        verification_result: String(result.verification_result || result.review_result || '').trim().toLowerCase(),
        result_packet_path: String(result.result_packet_path || ''),
      };
    }
  }
  for (const nodeId of transition.invalidated_nodes || []) {
    completed.delete(nodeId);
    invalidated.add(nodeId);
    nodeStatuses.set(nodeId, 'invalidated');
    delete reviewResults[nodeId];
  }
  const currentNode = nextStageId || stageId;
  const currentStage = findStage(tpl, currentNode);
  return {
    ...graph,
    current_node: currentNode,
    asset_target: currentStage ? { ...currentStage.asset_target } : { ...graph.asset_target },
    completed_nodes: LIFECYCLE_NODES.map((node) => node.id).filter((id) => completed.has(id)),
    invalidated_nodes: LIFECYCLE_NODES.map((node) => node.id).filter((id) => invalidated.has(id)),
    review_results: reviewResults,
    last_transition_validation: transition.lifecycle_validation ? { ...transition.lifecycle_validation } : null,
    nodes: graph.nodes.map((node) => ({ ...node, status: nodeStatuses.get(node.id) || 'missing' })),
  };
}

function buildUnitLifecycleState(tpl, stageDef, scope) {
  const contract = (tpl && tpl.unit_lifecycle_contract) || unitLifecycle('workflow_batch', {});
  const stageId = stageDef ? stageDef.stage_id : '';
  return {
    unit_type: contract.unit_type || 'workflow_batch',
    status: 'active',
    current_scope: scope || '',
    current_stage: stageId,
    current_role: currentUnitRole(contract, stageId),
    stage_roles: contract.stage_roles || {},
    required_sequence: contract.required_sequence || [],
    completed_roles: [],
    last_quality_gate: '',
    last_trusted_artifact: '',
    closure_rule: contract.closure_rule || '',
    failure_policy: contract.failure_policy || '',
  };
}

function advanceUnitLifecycleState(existing, tpl, nextStageDef, result, now, options) {
  const contract = (tpl && tpl.unit_lifecycle_contract) || unitLifecycle('workflow_batch', {});
  const state = existing || buildUnitLifecycleState(tpl, nextStageDef, '');
  const completedRole = currentUnitRole(contract, result.stage_id || '');
  const completedRoles = Array.isArray(state.completed_roles) ? state.completed_roles.slice() : [];
  const completeCurrentStage = !options || options.completeCurrentStage !== false;
  if (completeCurrentStage && completedRole && !completedRoles.includes(completedRole)) completedRoles.push(completedRole);
  const nextStageId = nextStageDef ? nextStageDef.stage_id : '';
  return {
    ...state,
    status: nextStageId ? 'active' : 'completed',
    updated_at: now,
    current_stage: nextStageId || result.stage_id || '',
    current_role: nextStageId ? currentUnitRole(contract, nextStageId) : 'handoff_and_next',
    completed_roles: completedRoles,
    last_quality_gate: completeCurrentStage && completedRole === 'quality_gate' ? (result.verification_result || result.output_health_result || 'completed') : (state.last_quality_gate || ''),
    last_trusted_artifact: completeCurrentStage ? (trustedArtifactFromResult(result) || state.last_trusted_artifact || '') : (state.last_trusted_artifact || ''),
  };
}

function blocked(status, messageOrFindings) {
  const findings = Array.isArray(messageOrFindings)
    ? messageOrFindings
    : [{ field: status, message: messageOrFindings }];
  return { schemaVersion: SCHEMA_VERSION, status, findings };
}

function print(result, json) {
  if (json) console.log(JSON.stringify(result, null, 2));
  else console.log(`${result.status || 'ok'}`);
}

function compactActivatedResult(result) {
  if (!result || !['activated', 'stage_started'].includes(String(result.status || '')) || !result.task) return result;
  const task = result.task;
  const execution = task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : null;
  const context = execution && execution.stage_context_packet && typeof execution.stage_context_packet === 'object'
    ? execution.stage_context_packet
    : null;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: result.status,
    previous_workflow_id: String(result.previous_workflow_id || ''),
    task: {
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      status: String(task.status || ''),
      state_version: Number(task.state_version || 0),
      current_stage: String(task.current_stage || ''),
      current_step: String(task.current_step || ''),
      scope: String(task.scope || ''),
      project_identity: task.project_identity || null,
      pending_action: task.pending_action || null,
      stage_execution: execution ? {
        status: String(execution.status || ''),
        stage_id: String(execution.stage_id || ''),
        step_id: String(execution.step_id || ''),
        owner_module: String(execution.owner_module || ''),
        write_set: Array.isArray(execution.write_set) ? execution.write_set : [],
        expected_result_packet: String(execution.expected_result_packet || ''),
        draft_target: String(execution.draft_target || ''),
        repair_target: String(execution.repair_target || ''),
        stage_context_packet: context ? {
          packet_md: String(context.packet_md || ''),
          estimated_tokens: Number(context.estimated_tokens || 0),
          token_budget: Number(context.token_budget || 0),
        } : null,
        execution_command: String(execution.execution_command || ''),
        resume_hint: String(execution.resume_hint || ''),
      } : null,
    },
    task_overview: result.task_overview || null,
    visible_response: result.visible_response || null,
  };
}

function main() {
  const args = parseArgs(process.argv);
  const effective = buildEffectiveTemplates(args.privateRegistryRoot, args.noPrivateRegistry);
  ACTIVE_TEMPLATES = effective.templates;
  ACTIVE_REGISTRIES = effective.registries;
  let result;
  let release = null;
  const mutating = isMutatingCommand(args.command)
    && (args.command !== 'migrate-legacy' || args.write);
  try {
    if (mutating) release = acquireProjectLock(path.resolve(args.projectRoot), `workflow-state-machine:${args.command}`);
    result = dispatchCommand(args.command, {
      templates: () => commandTemplates(),
      create: () => createTask(args),
      inspect: () => inspectTask(args),
      'task-overview': () => taskOverview(args),
      'resolve-action': () => resolveAction(args),
      'apply-result': () => applyResult(args),
      'next-candidates': () => nextCandidates(args),
      'switch-intent': () => switchIntent(args),
      activate: () => activateTask(args),
      'migrate-legacy': () => migrateLegacyWorkflows(args),
      'migrate-longform-successor': () => migrateLegacyLongformSuccessor(args),
      'reset-incompatible-review-batches': () => resetIncompatibleReviewBatches(args),
      'continue-review-with-legacy-evidence': () => continueReviewWithLegacyEvidence(args),
      'restore-incomplete-workflow': () => restoreIncompleteWorkflow(args),
      'reset-unmanaged-review-repair': () => resetUnmanagedReviewRepair(args),
      'reconcile-runtime': () => reconcileRuntime(args),
      'refresh-short-title-lock': () => refreshShortTitleLock(args),
      'resume-pending-short-feedback': () => resumePendingShortFeedback(args),
      'discard-short-feedback-item': () => discardShortFeedbackAndReconcile(args),
      'reclassify-short-feedback-item': () => reclassifyShortFeedbackAndReconcile(args),
      'migrate-short-lean-workflow': () => migrateShortLeanWorkflow(args),
    });
  } catch (error) {
    if (error && error.code === 'WORKFLOW_LOCKED') {
      result = blocked('blocked_workflow_locked', error.message);
    } else if (error && error.code === 'WORKFLOW_TASK_CONFLICT') {
      result = blocked('blocked_workflow_state_conflict', error.message);
    } else if (error && error.code === 'REVIEW_PLAN_EVIDENCE_INCOMPLETE') {
      result = blocked('blocked_review_plan_evidence_incomplete', `章节证据不完整或不可信：${error.evidence_status || 'unknown'}`);
    } else if (error && error.code === 'REVIEW_BATCH_PLAN_OVERSIZED') {
      result = blockedOversizedReviewPlan(error);
    } else {
      throw error;
    }
  } finally {
    if (release) release();
  }

  if (args.compact && args.command === 'activate') result = compactActivatedResult(result);
  print(result, args.json);
  process.exitCode = isConsoleErrorStatus(result.status) ? 2 : 0;
}

function isConsoleErrorStatus(status) {
  const value = String(status || '');
  if (!value.startsWith('blocked_')) return false;
  const handledWorkflowStates = new Set([
    'blocked_non_head_branch_projection',
    'blocked_selection_resolved',
    'blocked_selection_expired',
    'blocked_missing_visible_choice_binding',
    'blocked_stale_visible_choice',
    'blocked_visible_choice_hash_mismatch',
    'blocked_pending_action_project_mismatch',
    'blocked_stage_already_running',
    'blocked_free_text_disabled',
    'blocked_short_section_title_unconfirmed',
    'blocked_short_feedback_unreconciled',
    'blocked_short_section_plan_missing',
    'blocked_short_section_plan_conflict',
    'blocked_short_section_outside_plan',
    'blocked_short_full_story_assembly_missing',
    'blocked_longform_lifecycle_migration_required',
  ]);
  return !handledWorkflowStates.has(value);
}

function blockedOversizedReviewPlan(error) {
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'blocked_review_plan_oversized_chapter',
    chapter: {
      chapter_key: String(error.chapter_key || ''),
      source_chars: Number(error.source_chars || 0),
      weighted_source_chars: Number(error.weighted_source_chars || 0),
    },
    budget: { source_budget_chars: Number(error.source_budget_chars || 0) },
    recovery_action: {
      action_id: 'escalate_single_chapter_review',
      description: '缩小上下文或为该单章申请显式升级预算后重新创建审阅计划。',
    },
  };
}

main();
