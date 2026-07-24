#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { readFocusedTask } = require('./lib/workflow-task-authority');
const {
  isMigrationSuppressed,
  scanWorkflowMigrations,
} = require('./lib/workflow-legacy-migration');
const {
  listTaskFamilies,
  isUnfinishedFamily,
} = require('./lib/task-family-store');
const { buildLifecycleStatus } = require('./longform-lifecycle-status');
const { projectTaskActionView } = require('./lib/workflow-action-renderer');
const {
  taskHasOverview,
  taskOverviewPresentationRequired,
} = require('./lib/workflow-task-overview-state');

const REVIEW_EVIDENCE_PROTOCOL_VERSION = '2.0.0';
const SHORT_WORKFLOW_TYPES = new Set([
  'short_startup',
  'private_short_startup',
  'short_write',
  'short_revision',
  'short_deslop',
]);
const LONGFORM_LIFECYCLE_METADATA_PATHS = [
  '追踪/workflow/longform-lifecycle.json',
  '追踪/longform-lifecycle.json',
  '.longform-lifecycle.json',
  '追踪/workflow/longform-review-acceptances.json',
  '追踪/longform-review-acceptances.json',
];

const INBOX_ACTIONS = new Set([
  '',
  'show_inbox',
  'show_unfinished_tasks',
  'show_current_run',
  'show_smart_recommendations',
  'show_new_goal_options',
]);

const USAGE = `Usage: node scripts/workflow-task-inbox.js [--project-root <book-dir>] [--write] [--json]
  [--action <show_inbox|show_unfinished_tasks|show_current_run|show_smart_recommendations|show_new_goal_options>]
  [--selection <1-4>]

Builds a metadata-only startup task inbox for novel-assistant. It scans workflow,
short-form, review, deconstruction, and update/download state files without
reading chapter prose.`;

function parseArgs(argv) {
  const args = { projectRoot: '', json: false, write: false, action: '', selection: 0 };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '--write') args.write = true;
    else if (arg === '--selection') args.selection = Number(argv[++i] || 0);
    else if (arg === '--action') {
      args.action = argv[++i] || '';
      if (args.action === 'show_current_run') args.action = 'show_unfinished_tasks';
      if (!INBOX_ACTIONS.has(args.action)) fail(`Unknown --action: ${args.action}`);
    }
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!args.projectRoot) args.projectRoot = process.cwd();
  if (args.selection && (!Number.isInteger(args.selection) || args.selection < 1)) fail('invalid --selection');
  return args;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(1);
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
    if (!fs.existsSync(file)) return '';
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function runStateValidation(root) {
  const script = path.join(__dirname, 'workflow-state-validate.js');
  const result = spawnSync(process.execPath, [script, '--project-root', root, '--json'], {
    encoding: 'utf8',
    shell: false,
  });
  try {
    return JSON.parse(result.stdout || '{}');
  } catch (error) {
    return {
      status: 'blocked_state_validation_invalid_output',
      reason_code: 'invalid_validator_output',
      findings: [{ field: 'workflow-state-validate', message: error.message }],
    };
  }
}

function rel(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function hasUnfinishedStatus(value) {
  const status = String(value || '').toLowerCase();
  if (!status) return true;
  return ![
    'completed',
    'completed_verified',
    'done',
    'pass',
    'closed',
    'cancelled',
    'canceled',
  ].includes(status);
}

function isSupersededTask(task) {
  return String((((task || {}).lifecycle || {}).status) || '').toLowerCase() === 'superseded';
}

function hasUnsafeTaskDir(task) {
  const value = String((task || {}).task_dir || '');
  return Boolean(value) && (path.isAbsolute(value) || value.split(/[\\/]+/).includes('..'));
}

const STAGE_LABELS = {
  positioning: '定位当前目标',
  outline: '整理总纲',
  volume_outline: '整理卷纲',
  detail_outline: '整理细纲',
  chapter_contract: '确认章节契约',
  prose: '写正文',
  chapter_machine_gate: '检查章节质量门',
  chapter_repair_loop: '修订当前章节',
  drift_gate: '检查剧情漂移',
  state_delta: '更新状态账本',
  handoff: '生成交接包',
  range_lock: '确认审阅范围',
  evidence_scan: '扫描证据',
  classify_findings: '归类问题',
  repair_plan: '制定修复方案',
  user_scope_choice: '选择修复范围',
  repair_execution_plan: '生成受控修复方案',
  staged_repair_candidate: '准备候选修复稿',
  repair_machine_gate: '检查候选修复稿',
  execute_repair: '执行已确认修复方案',
  recheck: '复检修复结果',
  closure: '收束本轮任务',
  material_card: '确认素材卡',
  startup_scan: '扫描短篇状态',
  startup_menu: '选择短篇启动路径',
  freshness_window: '选择热点时间范围',
  info_source_pool: '选择资讯素材',
  material_learning: '生成并选择脑洞卡',
  project_seed: '建立独立短篇项目',
  short_setting: '整理短篇设定',
  platform_genre_lock: '锁定平台与题材方法',
  rhythm_pattern_selection: '选择节奏与爽点套路',
  section_outline: '整理小节大纲',
  section_plan_lock: '锁定总小节',
  short_structure_impact_audit: '检查结构变更影响',
  hook_value_gate: '检查看点与钩子',
  hook_retention_gate: '检查钩子保留',
  section_brief: '生成当前小节 Brief',
  first_section_brief: '生成第 1 节 Brief',
  next_section_brief: '生成下一节 Brief',
  draft_section: '写当前小节',
  draft_first_section: '写第 1 节',
  draft_next_section: '写下一节',
  section_machine_gate: '检查当前小节机器门',
  section_repair_loop: '修订当前小节',
  story_value_gate: '检查故事价值',
  feedback_impact_sync: '分析反馈影响',
  feedback_apply_patch: '回写已确认方案',
  quality_gate: '检查故事质量',
  section_candidate_compare: '对比候选稿',
  section_accept_anchor: '确认采用当前小节',
  full_story_assembly: '组装全篇',
  full_story_review: '全篇总编辑验收',
  deslop: '去 AI 味',
  final_check: '最终检查',
};

function humanStepLabel(value) {
  const key = String(value || '').trim();
  if (!key) return '';
  return STAGE_LABELS[key] || key.replace(/_/g, ' ');
}

function resumesRunningStage(task) {
  const execution = ((task || {}).stage_execution || {});
  return String(execution.status || '').toLowerCase() === 'running'
    && Boolean(String(execution.stage_id || execution.step_id || '').trim());
}

function resumesPausedStage(task) {
  const execution = ((task || {}).stage_execution || {});
  const taskStatus = String((task || {}).status || '').toLowerCase();
  const executionStatus = String(execution.status || '').toLowerCase();
  return taskStatus === 'paused'
    && executionStatus === 'paused'
    && Boolean(String(execution.stage_id || execution.step_id || '').trim());
}

function runningStageResumeLabel(task) {
  const execution = task.stage_execution || {};
  const stage = humanStepLabel(execution.step_id || execution.stage_id || task.current_step || task.current_stage || '');
  return `从断点继续${stage || '当前任务'}`;
}

function firstCandidateLabel(task) {
  if (resumesRunningStage(task)) return runningStageResumeLabel(task);
  const next = Array.isArray(task.next_candidates) ? task.next_candidates[0] : null;
  if (next && typeof next === 'object' && next.label) return String(next.label);
  if (typeof next === 'string' && next.trim()) return next.trim();
  if (task.current_step) return `继续${humanStepLabel(task.current_step)}`;
  if (task.current_stage) return `继续${humanStepLabel(task.current_stage)}`;
  if (task.workflow_type) return `继续${task.workflow_type}`;
  return '继续当前任务';
}

function parseNumericRange(value) {
  const match = String(value || '').match(/(\d+)\s*[-到至~]\s*(\d+)/);
  if (!match) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  return Number.isInteger(start) && Number.isInteger(end) && start > 0 && end >= start ? { start, end } : null;
}

function terminalReviewBatch(batch) {
  return ['completed', 'completed_verified', 'done'].includes(String((batch || {}).status || '').toLowerCase());
}

function safeProjectFile(root, relativePath) {
  if (!relativePath || path.isAbsolute(relativePath)) return '';
  const resolved = path.resolve(root, relativePath);
  return resolved === root || resolved.startsWith(`${root}${path.sep}`) ? resolved : '';
}

function reviewPacketIsProtocolCompatible(root, task, batch) {
  const fallback = `${task.task_dir}/result-packets/evidence_scan.batch-${batch.id}.result.json`;
  const packetFile = safeProjectFile(root, String(batch.accepted_result_packet || batch.result_packet || fallback));
  const packet = packetFile ? readJson(packetFile) : null;
  const range = parseNumericRange(batch.range);
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

function firstIncompatibleCompletedReviewBatch(root, task) {
  if (String((task || {}).workflow_type || '') !== 'review_repair') return null;
  const batches = (((task || {}).review_batches || {}).batches || []);
  if (!Array.isArray(batches)) return null;
  return batches.find(batch => terminalReviewBatch(batch) && !reviewPacketIsProtocolCompatible(root, task, batch)) || null;
}

function addReviewReacceptanceCandidate(root, candidates, task, source) {
  const batch = firstIncompatibleCompletedReviewBatch(root, task);
  if (!batch) return false;
  const range = String(batch.range || '');
  const label = `旧批次证据不符合当前验收协议（从 ${range} 开始）`;
  addCandidate(candidates, {
    id: task.workflow_id,
    workflow_type: 'review_repair',
    label,
    title: label,
    visible_stage: '重新验收旧审阅批次',
    scope_label: String(task.scope || ((task.review_batches || {}).parent_scope) || ''),
    last_trusted_artifact: extractTrustedArtifact(task),
    stop_reason: '旧批次协议不兼容，等待选择重新验收或带警告继续',
    next_actions: [
      {
        number: 1, label: `重新验收 ${range} 并继续原任务`, action_id: 'reset_incompatible_review_batches',
        target_stage: 'evidence_scan', risk_level: 'medium', requires_user_confirm: true,
        execution_command: `node scripts/workflow-state-machine.js reset-incompatible-review-batches --project-root <book-root> --workflow-id ${task.workflow_id} --confirm --json`,
      },
      {
        number: 2, label: '保留旧证据并从下一批继续', action_id: 'continue_review_with_legacy_evidence',
        target_stage: 'evidence_scan', risk_level: 'medium', requires_user_confirm: true,
        execution_command: `node scripts/workflow-state-machine.js continue-review-with-legacy-evidence --project-root <book-root> --workflow-id ${task.workflow_id} --confirm --json`,
      },
      { number: 3, label: '查看旧批次最后可信产物', action_id: 'inspect_legacy_review_evidence', risk_level: 'low', requires_user_confirm: false },
      { number: 4, label: '暂停并返回', action_id: 'pause', risk_level: 'low', requires_user_confirm: false },
    ],
    source,
    status: 'reacceptance_required',
    resume_hint: `/novel-assistant ${label}`,
    risk_level: 'medium',
    action: 'reset_incompatible_review_batches',
    execution_command: `node scripts/workflow-state-machine.js reset-incompatible-review-batches --project-root <book-root> --workflow-id ${task.workflow_id} --confirm --json`,
    detail_lines: ['重新验收可获得完整可信结论；保留旧证据会记录质量债务，并用新版协议继续后续批次。'],
  });
  return true;
}

function addCandidate(candidates, candidate) {
  const id = candidate.id || `${candidate.workflow_type}-${candidates.length + 1}`;
  if (candidates.some((item) => item.id === id)) return;
  candidates.push({
    id,
    workflow_type: candidate.workflow_type,
    label: candidate.label,
    title: candidate.title || candidate.label,
    visible_stage: candidate.visible_stage || '',
    scope_label: candidate.scope_label || '',
    last_trusted_artifact: candidate.last_trusted_artifact || '',
    stop_reason: candidate.stop_reason || '',
    next_actions: Array.isArray(candidate.next_actions) ? candidate.next_actions : [],
    free_text_enabled: candidate.free_text_enabled !== false,
    source: candidate.source,
    status: candidate.status || '',
    resume_hint: candidate.resume_hint || '/novel-assistant 继续',
    risk_level: candidate.risk_level || 'low',
    action: candidate.action || 'resume',
    execution_command: candidate.execution_command || '',
    activation_command: candidate.activation_command || '',
    reconstructed: Boolean(candidate.reconstructed),
    migration: candidate.migration || null,
    detail_lines: Array.isArray(candidate.detail_lines) ? candidate.detail_lines : [],
    action_resolution: candidate.action_resolution || null,
	    task_family_id: candidate.task_family_id || '',
	    head_workflow_id: candidate.head_workflow_id || '',
	    paused_branch_count: Number(candidate.paused_branch_count) || 0,
	    project_id: candidate.project_id || '',
	    working_title: candidate.working_title || '',
	    selected_material_id: candidate.selected_material_id || '',
	    selected_material_label: candidate.selected_material_label || '',
	    project_status: candidate.project_status || '',
	    task_overview_required: candidate.task_overview_required === true,
	    task_overview_label: candidate.task_overview_label || '',
	  });
}

function actionResolutionMetadata(task) {
  if (resumesRunningStage(task)) return null;
  const pending = task && task.pending_action && typeof task.pending_action === 'object' ? task.pending_action : null;
  if (!pending || !pending.id || !pending.visible_choice_hash || !Number.isInteger(Number(task.state_version))) return null;
  return {
    pending_action_id: String(pending.id),
    visible_choice_hash: String(pending.visible_choice_hash),
    state_version: Number(task.state_version),
    book_root: String(task.book_root || ''),
  };
}

function extractTrustedArtifact(task) {
  return String(
    (((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact)
      || ((task.unit_lifecycle || {}).last_trusted_artifact)
      || task.last_trusted_artifact
      || task.last_report
      || ''
  );
}

function normalizeNextActions(task, fallbackLabel) {
  if (resumesRunningStage(task)) {
    const execution = task.stage_execution || {};
    return [{
      number: 1,
      label: runningStageResumeLabel(task),
      action_id: 'resume_from_checkpoint',
      target_stage: '',
      risk_level: '',
      action_resolution: null,
      interaction_mode: 'resume_stage',
      resume_hint: String(execution.resume_hint || ''),
      stage_completion_command: String(execution.execution_command || ''),
    }];
  }
  if (resumesPausedStage(task)) {
    const workflowId = String(task.workflow_id || '');
    return [
      {
        number: 1,
        label: `继续${humanStepLabel(task.current_stage || task.current_step || '当前阶段')}（推荐）`,
        action_id: 'activate_workflow',
        interaction_mode: 'execute_command',
        execution_command: `node scripts/workflow-state-machine.js activate --project-root . --workflow-id ${workflowId} --compact --json`,
      },
      {
        number: 2,
        label: '查看当前进度与依据',
        action_id: 'inspect_current_state',
        interaction_mode: 'execute_command',
        execution_command: 'node scripts/workflow-state-machine.js inspect --project-root . --json',
      },
      { number: 3, label: '开启新任务', action_id: 'new_goal', interaction_mode: 'semantic_only' },
      { number: 4, label: '输入其他要求', action_id: 'free_text', interaction_mode: 'semantic_only' },
    ];
  }
  const pending = task && task.pending_action && typeof task.pending_action === 'object' ? task.pending_action : {};
  const options = Array.isArray(pending.options) ? pending.options : [];
  if (options.length > 0) {
    const resolution = actionResolutionMetadata(task);
    return options.slice(0, 4).map((option, index) => ({
      number: Number(option.number) || index + 1,
      label: localizedActionLabel(option, index),
      action_id: String(option.action_id || option.action || ''),
      target_stage: String(option.target_stage || ''),
      risk_level: String(option.risk_level || ''),
      action_resolution: resolution,
    }));
  }
  const next = Array.isArray(task.next_candidates) ? task.next_candidates : [];
  if (next.length > 0) {
    return next.slice(0, 4).map((item, index) => {
      if (typeof item === 'string') {
        return { number: index + 1, label: item, action_id: item, target_stage: '', risk_level: '' };
      }
      return {
        number: Number(item.number) || index + 1,
        label: String(item.label || item.action || `下一步 ${index + 1}`),
        action_id: String(item.action_id || item.action || ''),
        target_stage: String(item.target_stage || ''),
        risk_level: String(item.risk_level || ''),
      };
    });
  }
  return [{ number: 1, label: fallbackLabel || '继续当前任务', action_id: 'resume', target_stage: '', risk_level: '' }];
}

function requiresTaskOverview(task) {
  return taskOverviewPresentationRequired(task);
}

function taskOverviewStageLabel(task) {
  if (!taskHasOverview(task)) return '';
  const queue = task && task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (queue && Array.isArray(queue.items) && queue.items.length > 0) {
    const completed = queue.items.filter(item => String((item || {}).status || '') === 'accepted').length;
    return `整篇回炉（${completed}/${queue.items.length}）`;
  }
  return `任务总览｜${humanStepLabel(task.current_stage || task.current_step || '')}`;
}

function localizedActionLabel(option, index) {
  const raw = String(option.label || option.action_id || option.action || `下一步 ${index + 1}`).trim();
  const targetStage = String(option.target_stage || '').trim();
  const humanStage = humanStepLabel(targetStage);
  if (!targetStage || humanStage === targetStage) return raw;
  const rawStage = targetStage.replace(/_/g, ' ');
  if (raw === targetStage || raw === rawStage || raw === `继续 ${targetStage}` || raw === `继续 ${rawStage}` || raw === `继续${targetStage}`) {
    return `继续${humanStage}`;
  }
  return raw;
}

function shortProjectIdentity(root, task) {
  if (!['short_write', 'short_startup', 'private_short_startup'].includes(String((task || {}).workflow_type || ''))) return null;
  const embedded = task && task.project_identity && typeof task.project_identity === 'object'
    ? task.project_identity
    : null;
  const state = embedded || readJson(path.join(root, '追踪', 'private-short-extension', 'project-state.json'));
  if (!state || state.__error) return null;
  if (state.workflow_id && String(state.workflow_id) !== String((task || {}).workflow_id || '')) return null;
  const workingTitle = String(state.working_title || state.title || '').trim();
  if (!workingTitle) return null;
  const selected = state.selected_material && typeof state.selected_material === 'object'
    ? state.selected_material
    : {};
  return {
    project_id: String(state.project_id || ''),
    working_title: workingTitle,
    selected_material_id: String(selected.card_id || state.selected_material_id || ''),
    selected_material_label: String(selected.label || state.selected_material_label || ''),
    project_status: String(state.status || ''),
  };
}

function projectIdentityCandidateFields(root, task) {
  const identity = shortProjectIdentity(root, task);
  if (!identity) return {};
	  return {
	    project_id: identity.project_id,
	    working_title: identity.working_title,
	    selected_material_id: identity.selected_material_id,
	    selected_material_label: identity.selected_material_label,
	    project_status: identity.project_status,
	    detail_lines: [
	      identity.working_title ? `当前作品：${identity.working_title}` : '',
	      identity.selected_material_label ? `已选素材：${identity.selected_material_label}` : '',
	    ].filter(Boolean),
	  };
	}

function titleFromTask(root, task, fallback) {
  const identity = shortProjectIdentity(root, task);
  const title = String((identity || {}).working_title || task.title || task.user_goal || ((task.lifecycle || {}).user_goal) || fallback || '继续当前任务').trim();
  return taskHasOverview(task) && (identity || {}).working_title ? `整篇回炉《${title}》` : title;
}

function stopReasonFromTask(task) {
  if (resumesRunningStage(task)) return '当前阶段已开始，可从断点继续';
  const raw = String(
    ((task.machine || {}).next_stop_reason)
      || task.stop_reason
      || ((task.lifecycle || {}).stop_reason)
      || '等待选择下一步'
  );
  const visible = {
    ready_for_current_stage: '等待继续当前阶段',
    ready_next_stage: '当前阶段已完成，准备进入下一阶段',
    stage_running_waiting_result_packet: '当前阶段执行中，等待可信回执',
    waiting_result_packet: '等待当前阶段可信回执',
    waiting_user_choice: '等待选择下一步',
    paused: '已暂停并保存断点',
  };
  return visible[raw] || raw;
}

function buildTaskCard(candidate, index) {
  const overviewRequired = candidate.task_overview_required === true;
  const visibleStage = candidate.task_overview_label || candidate.visible_stage || humanStepLabel(candidate.current_stage || candidate.current_step || '');
  const stopReason = overviewRequired ? '等待进入任务总览' : candidate.stop_reason || '等待选择下一步';
  const artifact = candidate.last_trusted_artifact || '';
  const taskCommand = String(candidate.execution_command || candidate.activation_command || '');
  const display = [
    `${index + 1}. ${candidate.title || candidate.label}｜阶段：${visibleStage || '待确认'}｜停靠：${stopReason}`,
    artifact ? `   最后可信产物：${artifact}` : '',
    ...candidate.detail_lines.map((line) => `   ${line}`),
  ].filter(Boolean).join('\n');
  return {
    number: index + 1,
    id: candidate.id,
    workflow_type: candidate.workflow_type,
    title: candidate.title || candidate.label,
    visible_stage: visibleStage,
    scope_label: candidate.scope_label || '',
    last_trusted_artifact: artifact,
    stop_reason: stopReason,
    status: candidate.status || '',
    risk_level: candidate.risk_level || '',
    source: candidate.source || '',
    resume_hint: candidate.resume_hint || '',
    next_actions: overviewRequired
      ? [
        {
          number: 1,
          label: '进入任务总览（推荐）',
          action_id: 'open_task_overview',
          interaction_mode: taskCommand ? 'execute_command' : 'semantic_only',
          execution_command: taskCommand,
        },
        {
          number: 2,
          label: '查看断点、依据与最后可信产物',
          action_id: 'inspect_current_state',
          interaction_mode: 'execute_command',
          execution_command: `node scripts/workflow-state-machine.js inspect --project-root <book-root> --compact --json`,
        },
        {
          number: 3,
          label: '返回任务收件箱',
          action_id: 'show_task_inbox',
          interaction_mode: 'execute_command',
          execution_command: `node scripts/workflow-task-inbox.js --project-root <book-root> --json`,
        },
        {
          number: 4,
          label: '输入其他要求',
          action_id: 'free_text',
          interaction_mode: 'semantic_only',
          execution_command: '',
        },
      ]
      : Array.isArray(candidate.next_actions) && candidate.next_actions.length > 0
      ? candidate.next_actions
      : [{ number: 1, label: candidate.label || '继续当前任务', action_id: candidate.action || 'resume' }],
    free_text_enabled: candidate.free_text_enabled !== false,
    action_resolution: candidate.action_resolution || null,
    interaction_mode: taskCommand ? 'execute_command' : 'semantic_only',
    execution_command: taskCommand,
    migration: candidate.migration || null,
	    task_family_id: candidate.task_family_id || '',
	    head_workflow_id: candidate.head_workflow_id || '',
	    paused_branch_count: Number(candidate.paused_branch_count) || 0,
	    project_id: candidate.project_id || '',
	    working_title: candidate.working_title || '',
	    selected_material_id: candidate.selected_material_id || '',
	    selected_material_label: candidate.selected_material_label || '',
    project_status: candidate.project_status || '',
	    task_overview_required: candidate.task_overview_required === true,
	    task_overview_label: candidate.task_overview_label || '',
    display,
  };
}

const GROUPS = [
  {
    workflow_type: 'long_write',
    label: '长篇写作',
    childTypes: ['long_daily_write', 'long_startup', 'long_expansion_transaction', 'long_revision', 'workflow_task'],
  },
  {
    workflow_type: 'short_write',
    label: '短篇创作',
    childTypes: Array.from(SHORT_WORKFLOW_TYPES),
  },
  {
    workflow_type: 'review_repair',
    label: '审阅与修复',
    childTypes: ['range_review', 'review_repair', 'short_review', 'anti_ai_workflow'],
  },
  {
    workflow_type: 'deconstruction_learning',
    label: '拆文与素材学习',
    childTypes: ['full_book_deconstruction', 'short_deconstruction', 'scan_learning', 'long_analyze', 'short_analyze'],
  },
  {
    workflow_type: 'market_scan',
    label: '市场趋势与扫榜',
    childTypes: ['long_scan', 'short_scan'],
  },
  {
    workflow_type: 'cover',
    label: '封面设计',
    childTypes: ['cover'],
  },
  {
    workflow_type: 'download_import',
    label: '下载导入与续更',
    childTypes: ['download_update', 'novel_download', 'story_import'],
  },
  {
    workflow_type: 'legacy_recovery',
    label: '项目状态恢复',
    childTypes: ['legacy_project_recovery', 'legacy_long_recovery', 'legacy_short_recovery', 'legacy_review_recovery'],
  },
  {
    workflow_type: 'maintenance',
    label: '协作环境与维护',
    childTypes: ['setup_update', 'project_runtime_update', 'skill_update'],
  },
];

const NEW_GOAL_OPTIONS = [
  {
    number: 1,
    label: '新开长篇',
    workflow_type: 'long_startup',
    action: 'create_workflow:long_startup',
    description: '先完成题材定位、核心承诺、人物、剧情引擎、总纲、卷纲和前置细纲；不直接写正文。',
  },
  {
    number: 2,
    label: '新开短篇',
    workflow_type: 'short_write',
    action: 'create_workflow:short_write',
    description: '进入完整短篇生命周期：素材、设定、节奏、小节大纲、逐节 Brief、正文验收与完稿。',
  },
  {
    number: 3,
    label: '初始化新项目',
    workflow_type: 'project_setup',
    action: 'create_workflow:project_setup',
    description: '部署协作环境、目录结构和 workflow 记忆；不修改正文。',
  },
  {
    number: 4,
    label: '长篇扫榜',
    workflow_type: 'long_scan',
    action: 'create_workflow:long_scan',
    description: '锁定平台和数据来源，验证趋势后输出长篇选题候选与作者吸收卡。',
  },
  {
    number: 5,
    label: '短篇扫榜',
    workflow_type: 'short_scan',
    action: 'create_workflow:short_scan',
    description: '锁定短篇平台和样本窗口，验证情绪趋势、饱和风险与复扫时间。',
  },
  {
    number: 6,
    label: '短篇拆文',
    workflow_type: 'short_analyze',
    action: 'create_workflow:short_analyze',
    description: '锁定合法来源与拆解范围，输出可验证的结构分析和禁抄边界。',
  },
  {
    number: 7,
    label: '制作书籍封面',
    workflow_type: 'cover',
    action: 'create_workflow:cover',
    description: '先锁定视觉方向和输出目标；任何出图或覆盖现有封面前都需要确认。',
  },
  {
    number: 8,
    label: '输入其他新目标',
    workflow_type: 'free_text',
    action: 'free_text_new_goal',
    description: '直接描述你的写作、审阅、拆文、导入或修复目标。',
  },
];

const ACTIVE_PROJECT_GOAL_OPTIONS = [
  {
    number: 1,
    label: '保留已有任务，开启当前作品写作或回炉目标',
    workflow_type: 'current_project_write',
    action: 'create_workflow:current_project_write',
    description: '围绕当前作品继续写作、章节 Brief、章节回炉、扩容缩容或正文修订；只切换本会话焦点，已有任务保持可恢复。',
  },
  {
    number: 2,
    label: '保留已有任务，开启当前作品审阅或修复目标',
    workflow_type: 'current_project_review_repair',
    action: 'create_workflow:current_project_review_repair',
    description: '围绕当前作品做范围审阅、伏笔钩子检查、情节连贯性、人物稳定性或 AI 味修复；已有任务保持可恢复。',
  },
  {
    number: 3,
    label: '保留已有任务，开启当前作品素材学习或拆文目标',
    workflow_type: 'current_project_learning',
    action: 'create_workflow:current_project_learning',
    description: '围绕当前作品整理拆文库、吸收技巧卡、扫榜学习或补充素材；不覆盖现有任务。',
  },
  {
    number: 4,
    label: '输入其他当前作品目标',
    workflow_type: 'free_text',
    action: 'free_text_current_project_goal',
    description: '直接描述你要对当前作品做的写作、审阅、拆文、导入、修复或维护动作。',
  },
];

function groupForCandidate(candidate) {
  const configured = GROUPS.find((group) => group.childTypes.includes(candidate.workflow_type));
  if (configured) return configured;
  if (String(candidate.workflow_type || '').startsWith('long_')) return GROUPS[0];
  if (String(candidate.workflow_type || '').startsWith('short_')) return GROUPS[1];
  return {
    workflow_type: 'other_workflow',
    label: '其他任务',
    childTypes: [],
  };
}

function buildWorkflowGroups(candidates) {
  const byType = new Map();
  for (const candidate of candidates) {
    const group = groupForCandidate(candidate);
    if (!byType.has(group.workflow_type)) {
      byType.set(group.workflow_type, {
        workflow_type: group.workflow_type,
        label: group.label,
        unfinished_count: 0,
        recommended: false,
        next_action: '',
        candidates: [],
      });
    }
    const entry = byType.get(group.workflow_type);
    entry.candidates.push(candidate);
    entry.unfinished_count += 1;
  }

  const order = new Map(GROUPS.map((group, index) => [group.workflow_type, index]));
  const groups = Array.from(byType.values()).sort((a, b) => {
    const left = order.has(a.workflow_type) ? order.get(a.workflow_type) : 999;
    const right = order.has(b.workflow_type) ? order.get(b.workflow_type) : 999;
    return left - right;
  });

  groups.forEach((group, index) => {
    group.number = index + 1;
    group.recommended = index === 0;
    group.next_action = group.candidates[0] ? group.candidates[0].label : '';
    group.display = `${index + 1}. ${group.label}（${group.unfinished_count} 个未完成）`;
  });
  return groups;
}

function normalizeRecommendation(item, index, workflowType) {
  if (typeof item === 'string') {
    return {
      number: index + 1,
      label: item,
      action: item,
      workflow_type: workflowType || '',
    };
  }
  return {
    number: index + 1,
    label: item.label || item.action || `下一步 ${index + 1}`,
    action: item.action || item.action_id || item.label || `next_${index + 1}`,
    action_id: item.action_id || item.action || '',
    workflow_type: item.workflow_type || workflowType || '',
    target: item.target || '',
  };
}

function isTerminalCompletionNotice(item) {
  const label = String((item || {}).label || '');
  const action = String((item || {}).action || (item || {}).action_id || '');
  return action === 'start_new_workflow' && /工作流完成|可发布|流程已完成/.test(label);
}

function derivePostCompletionRecommendations(task) {
  if (!task || task.__error) return [];
  if (!['completed', 'completed_verified', 'done'].includes(String(task.status || '').toLowerCase())) return [];
  if (Array.isArray(task.recommended_next) && task.recommended_next.length > 0) {
    return task.recommended_next.map((item, index) => normalizeRecommendation(item, index, task.workflow_type));
  }

  const workflowType = String(task.workflow_type || '');
  const step = String(task.completed_step || task.current_step || task.current_stage || '').toLowerCase();
  const longStartupMap = [
    {
      match: ['market_positioning', 'market positioning', '选题', '题材定位'],
      next: ['进入核心设定', '建立主线承诺', '选择 3-5 张作者吸收卡'],
    },
    {
      match: ['core_promise', 'core promise', '核心设定', '主线承诺'],
      next: ['补人物关系压力', '建立角色不变量', '进入剧情引擎设计'],
    },
    {
      match: ['character_relationship', 'character relationship', '人物关系', '角色关系'],
      next: ['设计剧情引擎', '建立伏笔债表', '补世界规则'],
    },
    {
      match: ['plot_engine', 'plot engine', '剧情引擎'],
      next: ['生成全书大纲', '生成第一卷卷纲', '规划前 10 章追读节点'],
    },
    {
      match: ['macro_outline', 'macro outline', '大纲', '总纲'],
      next: ['生成第一卷卷纲', '补齐前 10 章细纲', '进入第 1 章 Chapter Contract'],
    },
    {
      match: ['detailed_outline', 'detailed outline', '细纲'],
      next: ['进入第 1 章 Chapter Contract', '运行开写前体检', '开始第 1 章正文生产'],
    },
  ];

  if (workflowType === 'long_startup' || workflowType === 'long_write') {
    const matched = longStartupMap.find((row) => row.match.some((keyword) => step.includes(keyword)));
    if (matched) return matched.next.map((item, index) => normalizeRecommendation(item, index, workflowType));
  }

  if (workflowType === 'long_daily_write') {
    return ['运行漂移门控', '更新 State Delta 与交接包', '继续下一章写作'].map((item, index) => normalizeRecommendation(item, index, workflowType));
  }
  if (workflowType === 'range_review') {
    return ['执行 S1/S2 修复', '补审未审 gap', '复检已修复范围'].map((item, index) => normalizeRecommendation(item, index, workflowType));
  }
  if (workflowType === 'full_book_deconstruction') {
    return ['生成作者吸收卡', '基于拆文报告开书', '把可复用技巧写入素材库'].map((item, index) => normalizeRecommendation(item, index, workflowType));
  }
  return [];
}

function scanTaskFamilies(root, candidates, suppressedWorkflowIds) {
  const inventory = listTaskFamilies(root);
  const coveredWorkflowIds = new Set();
  for (const family of inventory.families) {
    for (const branch of family.branches || []) coveredWorkflowIds.add(String(branch.workflow_id || ''));
    if (!isUnfinishedFamily(family) || suppressedWorkflowIds.has(String(family.head_workflow_id || ''))) continue;
    const headId = String(family.head_workflow_id || '');
    const file = headId ? path.join(root, '追踪', 'workflow', 'tasks', headId, 'task.json') : '';
    const task = file ? readJson(file) : null;
    if (!task || task.__error || hasUnsafeTaskDir(task)) continue;
    const pausedBranchCount = (family.branches || []).filter((branch) => String(branch.workflow_id || '') !== headId
      && ['paused', 'invalidated'].includes(String(branch.status || '').toLowerCase())).length;
    addCandidate(candidates, {
      ...projectIdentityCandidateFields(root, task),
      id: String(family.task_family_id),
      task_family_id: String(family.task_family_id),
      head_workflow_id: headId,
      paused_branch_count: pausedBranchCount,
      workflow_type: task.workflow_type || family.identity?.workflow_class || 'workflow_task',
      label: firstCandidateLabel(task),
      title: titleFromTask(root, task, firstCandidateLabel(task)),
      visible_stage: humanStepLabel(task.current_stage || task.current_step || ''),
      scope_label: String(task.scope || ((task.lifecycle || {}).scope) || ''),
      last_trusted_artifact: extractTrustedArtifact(task),
      stop_reason: stopReasonFromTask(task),
      next_actions: normalizeNextActions(task, firstCandidateLabel(task)),
      action_resolution: actionResolutionMetadata(task),
      free_text_enabled: !task.pending_action || task.pending_action.free_text_enabled !== false,
      source: rel(root, file),
      // task.json is authoritative; family.status is a projection and may lag
      // after an older client pauses or completes the head branch.
      status: task.status || family.status || '',
      resume_hint: task.resume_hint || '/novel-assistant 继续',
      risk_level: task.risk_level || 'medium',
      action: 'resume_workflow_family',
      task_overview_required: requiresTaskOverview(task),
      task_overview_label: taskOverviewStageLabel(task),
      activation_command: `node scripts/workflow-state-machine.js activate --project-root <book-root> --workflow-id ${headId} --compact --json`,
    });
  }
  return { coveredWorkflowIds, inventory };
}

function focusedTaskBelongsToMultiBranchFamily(root, task) {
  const workflowId = String((task || {}).workflow_id || '');
  if (!workflowId) return false;
  const inventory = listTaskFamilies(root);
  return (inventory.families || []).some((family) => {
    if (!isUnfinishedFamily(family)) return false;
    const branches = family.branches || [];
    const containsFocused = branches.some((branch) => String(branch.workflow_id || '') === workflowId);
    return containsFocused && branches.length > 1;
  });
}

function scanWorkflow(root, candidates, suppressedWorkflowIds) {
  const focused = readFocusedTask(root);
  const file = path.join(root, '追踪', 'workflow', 'current-task.json');
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  if (!task || task.__error || hasUnsafeTaskDir(task) || isSupersededTask(task) || suppressedWorkflowIds.has(task.workflow_id)) return;
  if (addReviewReacceptanceCandidate(root, candidates, task, rel(root, file))) return;
  if (!hasUnfinishedStatus(task.status)) return;
  addCandidate(candidates, {
    ...projectIdentityCandidateFields(root, task),
    id: task.workflow_id || 'workflow-current-task',
    workflow_type: task.workflow_type || 'workflow_task',
    label: firstCandidateLabel(task),
    title: titleFromTask(root, task, firstCandidateLabel(task)),
    visible_stage: humanStepLabel(task.current_stage || task.current_step || ''),
    scope_label: String(task.scope || ((task.lifecycle || {}).scope) || ''),
    last_trusted_artifact: extractTrustedArtifact(task),
    stop_reason: stopReasonFromTask(task),
    next_actions: normalizeNextActions(task, firstCandidateLabel(task)),
    action_resolution: actionResolutionMetadata(task),
    free_text_enabled: !task.pending_action || task.pending_action.free_text_enabled !== false,
    source: rel(root, file),
    status: task.status || '',
    resume_hint: task.resume_hint || '/novel-assistant 继续',
    risk_level: task.risk_level || 'medium',
    action: 'resume_workflow',
    task_overview_required: requiresTaskOverview(task),
    task_overview_label: taskOverviewStageLabel(task),
    activation_command: `node scripts/workflow-state-machine.js activate --project-root <book-root> --workflow-id ${task.workflow_id || ''} --compact --json`,
  });
}

function scanTaskDirectories(root, candidates, suppressedWorkflowIds) {
  const tasksDir = path.join(root, '追踪', 'workflow', 'tasks');
  if (!fs.existsSync(tasksDir)) return;
  for (const entry of fs.readdirSync(tasksDir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    const file = path.join(tasksDir, entry.name, 'task.json');
    const task = readJson(file);
    if (!task || task.__error || hasUnsafeTaskDir(task) || isSupersededTask(task) || suppressedWorkflowIds.has(task.workflow_id)) continue;
    if (addReviewReacceptanceCandidate(root, candidates, task, rel(root, file))) continue;
    if (!hasUnfinishedStatus(task.status)) continue;
    addCandidate(candidates, {
      ...projectIdentityCandidateFields(root, task),
      id: task.workflow_id || entry.name,
      workflow_type: task.workflow_type || 'workflow_task',
      label: firstCandidateLabel(task),
      title: titleFromTask(root, task, firstCandidateLabel(task)),
      visible_stage: humanStepLabel(task.current_stage || task.current_step || ''),
      scope_label: String(task.scope || ((task.lifecycle || {}).scope) || ''),
      last_trusted_artifact: extractTrustedArtifact(task),
      stop_reason: stopReasonFromTask(task),
      next_actions: normalizeNextActions(task, firstCandidateLabel(task)),
      action_resolution: actionResolutionMetadata(task),
      free_text_enabled: !task.pending_action || task.pending_action.free_text_enabled !== false,
      source: rel(root, file),
      status: task.status || '',
      resume_hint: task.resume_hint || '/novel-assistant 继续',
      risk_level: task.risk_level || 'medium',
      action: 'resume_workflow',
      task_overview_required: requiresTaskOverview(task),
      task_overview_label: taskOverviewStageLabel(task),
      activation_command: `node scripts/workflow-state-machine.js activate --project-root <book-root> --workflow-id ${task.workflow_id || entry.name} --compact --json`,
    });
  }
}

function migrationTitle(item) {
  if (item.migration_source === 'novel-assistant/previous-version') return '升级旧版 novel-assistant 审阅任务';
  return '升级上游 oh-story 审阅任务';
}

function scanMigrationCandidates(candidates, items) {
  for (const item of items) {
    if (!isMigrationSuppressed(item)) continue;
    const title = migrationTitle(item);
    addCandidate(candidates, {
      id: item.workflow_id || item.id,
      workflow_type: 'review_repair',
      label: title,
      title,
      visible_stage: '迁移旧审阅任务',
      scope_label: String(item.scope || ''),
      stop_reason: item.reason || '等待确认迁移',
      next_actions: [{
        number: 1,
        label: '确认迁移旧任务',
        action_id: 'migrate_legacy_review_and_continue',
        target_stage: 'evidence_scan',
        risk_level: item.classification === 'confirm-required' ? 'high' : 'medium',
        requires_user_confirm: true,
      }],
      free_text_enabled: true,
      source: (item.source_paths || []).join(', '),
      status: 'migration_pending',
      risk_level: item.risk_level || 'medium',
      action: 'migrate_legacy_review_and_continue',
      migration: {
        source: item.migration_source,
        rollback_snapshot: item.rollback_snapshot,
        impact: item.impact,
      },
      detail_lines: [`来源：${item.migration_source}`, `回退快照：${item.rollback_snapshot || '迁移成功后创建'}`],
    });
  }
}

function visibleMigrationInventory(inventory) {
  const items = (inventory.items || []).filter(isMigrationSuppressed);
  const classifications = ['no-op', 'auto-safe', 'confirm-required', 'read-only-compatible', 'blocked'];
  return {
    ...inventory,
    sources_scanned: items.flatMap(item => item.source_paths || []).sort(),
    items,
    summary: Object.fromEntries(classifications.map(classification => [classification, items.filter(item => item.classification === classification).length])),
  };
}

function scanWorkflowCompletion(root) {
  const focused = readFocusedTask(root);
  return derivePostCompletionRecommendations(focused.authority.status === 'ok' ? focused.authority.task : null);
}

function addRecommendation(recommendations, label, action, reason = '', metadata = {}) {
  if (recommendations.some((item) => item.label === label || item.action === action)) return;
  recommendations.push({
    number: recommendations.length + 1,
    label,
    action,
    reason,
    ...metadata,
  });
}

function chapterGenerationAllowed(lifecycleStatus) {
  if (!lifecycleStatus || !Array.isArray(lifecycleStatus.assets)) return false;
  const required = [
    'master_outline', 'master_outline_review', 'volume_outline', 'volume_outline_review',
    'stage_detail_outline', 'detail_outline_review', 'chapter_brief', 'brief_review',
  ];
  const statuses = Object.fromEntries((lifecycleStatus.assets || []).map(asset => [asset.id, asset.status]));
  return required.every(id => statuses[id] === 'accepted');
}

function isShortProjectContext(root, candidates) {
  if ((candidates || []).some(candidate => SHORT_WORKFLOW_TYPES.has(String(candidate.workflow_type || '')))) return true;
  const projectState = readJson(path.join(root, '追踪', 'private-short-extension', 'project-state.json'));
  if (projectState && !projectState.__error) {
    const declaredShortProject = SHORT_WORKFLOW_TYPES.has(String(projectState.workflow_type || ''))
      || Boolean(projectState.project_id && projectState.selected_material);
    if (declaredShortProject) return true;
  }
  // 老项目兼容: 没有活跃任务也没有 project-state.json, 但有短篇创作资产
  // (正文.md + 设定.md + 小节大纲.md 或 写作Brief_第N节.md)时, 识别为短篇项目,
  // 避免误 fallback 到长篇生命周期检测并推荐"补全创作圣经"。
  const hasShortProse = fs.existsSync(path.join(root, '正文.md'));
  const hasShortSetting = fs.existsSync(path.join(root, '设定.md'));
  const hasShortOutline = fs.existsSync(path.join(root, '小节大纲.md'));
  const hasShortBrief = fs.existsSync(path.join(root, '追踪', 'private-short-extension', 'current-task.json'))
    || fs.readdirSync(root).some((name) => /^写作Brief_第\d+节\.md$/.test(name));
  if (hasShortProse && hasShortSetting && (hasShortOutline || hasShortBrief)) return true;
  return false;
}

function deriveSmartNewTaskRecommendations(root, candidates, postCompletionRecommendations, lifecycleStatus) {
  const recommendations = [];
  const shortProjectContext = isShortProjectContext(root, candidates);
  const lifecycleAction = lifecycleStatus && lifecycleStatus.recommended_actions
    ? lifecycleStatus.recommended_actions[0]
    : null;
  if (lifecycleAction && !shortProjectContext) {
    addRecommendation(
      recommendations,
      lifecycleAction.label,
      'longform_lifecycle_next',
      '根据当前作品的长篇生命周期状态确定',
      {
        lifecycle_action_id: lifecycleAction.action_id,
        target_asset: lifecycleAction.target_asset,
        blocking_gaps: lifecycleAction.blocking_gaps,
      },
    );
  }
  for (const item of postCompletionRecommendations.slice(0, 3)) {
    if (isTerminalCompletionNotice(item)) continue;
    addRecommendation(recommendations, item.label, item.action || item.label, '来自上一任务完成后的推荐下一步');
  }

  const proseDir = path.join(root, '正文');
  const outlineDir = path.join(root, '大纲');
  const foreshadowFile = path.join(root, '追踪', '伏笔.md');
  const reviewDir = path.join(root, '追踪', '审查报告');
  const deconstructionDir = path.join(root, '拆文库');
  // 短篇用 正文.md 单文件, 长篇用 正文/ 目录; 两种都要识别
  const hasProse = hasAnyMarkdownDeep(proseDir) || fs.existsSync(path.join(root, '正文.md'));
  const hasOutline = hasAnyMarkdownDeep(outlineDir) || fs.existsSync(path.join(root, '小节大纲.md'));
  const hasForeshadow = fs.existsSync(foreshadowFile);
  const hasReviewReports = countMarkdownFiles(reviewDir) > 0;
  const hasDeconstruction = countChildDirs(deconstructionDir) > 0;
  const activeTypes = new Set(candidates.map((candidate) => candidate.workflow_type));

  if (hasProse && chapterGenerationAllowed(lifecycleStatus) && !activeTypes.has('long_daily_write')) {
    addRecommendation(recommendations, '继续写作或生成下一章 Brief', 'start_or_resume_writing', '检测到正文资产');
  }
  if ((hasProse || hasOutline) && !activeTypes.has('range_review') && !activeTypes.has('review_repair') && !activeTypes.has('short_review')) {
    if (shortProjectContext) {
      addRecommendation(recommendations, '验收当前短篇（推荐）', 'start_short_review', '短篇已存在正文或大纲，建议先做全篇只读验收', {
        workflow_type: 'short_review',
        recommended: true,
        interaction_mode: 'execute_command',
        execution_command: [
          'node scripts/workflow-state-machine.js create',
          '--workflow-type short_review',
          `--project-root ${JSON.stringify(root)}`,
          `--scope ${JSON.stringify('全篇')}`,
          `--user-goal ${JSON.stringify('验收当前短篇')}`,
          '--json',
        ].join(' '),
      });
    } else {
      addRecommendation(recommendations, '审阅当前正文范围', 'start_range_review', '检测到正文/大纲资产');
    }
  }
  if (hasForeshadow) {
    addRecommendation(recommendations, '检查伏笔与钩子回收', 'review_foreshadow_hooks', '检测到追踪/伏笔.md');
  }
  if (hasReviewReports) {
    addRecommendation(recommendations, '复查历史审查报告未闭环项', 'review_previous_findings', '检测到历史审查报告');
  }
  if (hasDeconstruction) {
    addRecommendation(recommendations, '整理拆文库并生成可吸收技巧卡', 'learn_from_deconstruction', '检测到拆文库资产');
  }

  if (!recommendations.length && candidates.length === 0) {
    addRecommendation(recommendations, '开始长篇写作', 'start_longform', '没有检测到活跃写作任务');
    addRecommendation(recommendations, '开始短篇写作', 'start_shortform', '没有检测到活跃写作任务');
    addRecommendation(recommendations, '导入已有小说', 'import_existing_story', '可以从现有正文反向建立项目');
  }

  return recommendations.slice(0, 5).map((item, index) => ({ ...item, number: index + 1 }));
}

function scanReview(root, candidates) {
  const file = path.join(root, '追踪', 'review-state.json');
  const state = readJson(file);
  if (!state || state.__error || !hasUnfinishedStatus(state.status)) return;
  // A freshly initialized review ledger has `reviews: []` but no active
  // status/scope. It is bookkeeping, not a resumable review task.
  if (Array.isArray(state.reviews) && state.reviews.length === 0 && !state.status && !state.scope && !state.resume_hint) return;
  const scope = state.scope ? ` ${state.scope}` : '';
  addCandidate(candidates, {
    id: 'review-state',
    workflow_type: 'range_review',
    label: `继续审阅${scope}`.trim(),
    source: rel(root, file),
    status: state.status || '',
    resume_hint: state.resume_hint || `/novel-assistant 继续审阅${scope}`.trim(),
    risk_level: 'medium',
    action: 'resume_review',
  });
}

function parseProgressMarkdown(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*[:：]\s*(.+?)\s*$/);
    if (match) out[match[1].toLowerCase()] = match[2];
  }
  return out;
}

function scanAnalyze(root, candidates) {
  const base = path.join(root, '拆文库');
  if (!fs.existsSync(base)) return;
  for (const name of fs.readdirSync(base).sort()) {
    const file = path.join(base, name, '_progress.md');
    const text = readText(file);
    if (!text) continue;
    const progress = parseProgressMarkdown(text);
    if (!hasUnfinishedStatus(progress.status || progress.state)) continue;
    addCandidate(candidates, {
      id: `analyze-${name}`,
      workflow_type: 'full_book_deconstruction',
      label: `继续拆《${name}》`,
      source: rel(root, file),
      status: progress.status || progress.state || 'running',
      resume_hint: progress.resume || `/novel-assistant 继续拆《${name}》`,
      risk_level: 'medium',
      action: 'resume_deconstruction',
    });
  }
}

function scanDownloadUpdate(root, candidates) {
  const reportDir = path.join(root, 'downloads', '_reports');
  const file = path.join(reportDir, 'update-state.json');
  const state = readJson(file);
  if (!state || state.__error || !hasUnfinishedStatus(state.status)) return;
  const title = state.title || state.book_title || '连载项目';
  addCandidate(candidates, {
    id: 'download-update-state',
    workflow_type: 'download_update',
    label: `续更${title}`,
    source: rel(root, file),
    status: state.status || '',
    resume_hint: state.resume_hint || `/novel-assistant 续更${title}`,
    risk_level: 'low',
    action: 'resume_update_job',
  });
}

function countMarkdownFiles(dir) {
  try {
    if (!fs.existsSync(dir)) return 0;
    return fs.readdirSync(dir, { withFileTypes: true }).filter((entry) => entry.isFile() && entry.name.endsWith('.md')).length;
  } catch {
    return 0;
  }
}

function countChildDirs(dir) {
  try {
    if (!fs.existsSync(dir)) return 0;
    return fs.readdirSync(dir, { withFileTypes: true }).filter((entry) => entry.isDirectory()).length;
  } catch {
    return 0;
  }
}

function hasAnyMarkdownDeep(dir, maxDirs = 16) {
  try {
    if (!fs.existsSync(dir)) return false;
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    if (entries.some((entry) => entry.isFile() && entry.name.endsWith('.md'))) return true;
    let checked = 0;
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      checked += 1;
      if (checked > maxDirs) break;
      if (countMarkdownFiles(path.join(dir, entry.name)) > 0) return true;
    }
  } catch {
    return false;
  }
  return false;
}

function hasExistingProjectAssets(root) {
  return hasAnyMarkdownDeep(path.join(root, '正文'))
    || hasAnyMarkdownDeep(path.join(root, '大纲'))
    || hasAnyMarkdownDeep(path.join(root, '设定'))
    || fs.existsSync(path.join(root, '素材卡.md'))
    || fs.existsSync(path.join(root, '设定.md'))
    || fs.existsSync(path.join(root, '小节大纲.md'))
    || fs.existsSync(path.join(root, '正文.md'))
    || fs.existsSync(path.join(root, '正文_新版.md'))
    || countChildDirs(path.join(root, '拆文库')) > 0
    || fs.existsSync(path.join(root, '追踪', 'private-short-extension', 'cards', 'info-source-cards.jsonl'))
    || LONGFORM_LIFECYCLE_METADATA_PATHS.some(relativePath => fs.existsSync(path.join(root, relativePath)))
    || hasDurableWorkflowTask(root);
}

function hasDurableWorkflowTask(root) {
  const tasksDir = path.join(root, '追踪', 'workflow', 'tasks');
  try {
    return fs.readdirSync(tasksDir, { withFileTypes: true })
      .some((entry) => entry.isDirectory() && fs.existsSync(path.join(tasksDir, entry.name, 'task.json')));
  } catch (_) {
    return false;
  }
}

function deriveNewGoalOptions(root, candidates) {
  if ((Array.isArray(candidates) && candidates.length > 0) || hasExistingProjectAssets(root)) {
    return ACTIVE_PROJECT_GOAL_OPTIONS;
  }
  return NEW_GOAL_OPTIONS;
}

function scanLegacyProjectHints(root, candidates) {
  const workflowFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  const reviewFile = path.join(root, '追踪', 'review-state.json');
  const shortFile = path.join(root, '追踪', 'private-short-extension', 'current-task.json');
  if (fs.existsSync(workflowFile) || fs.existsSync(reviewFile) || fs.existsSync(shortFile)) return;

  const proseDir = path.join(root, '正文');
  const outlineDir = path.join(root, '大纲');
  const reviewReportDir = path.join(root, '追踪', '审查报告');
  const deconstructionDir = path.join(root, '拆文库');
  const hasProse = hasAnyMarkdownDeep(proseDir);
  const hasOutline = hasAnyMarkdownDeep(outlineDir);
  const reviewReportCount = countMarkdownFiles(reviewReportDir);
  const deconstructionCount = countChildDirs(deconstructionDir);

  if (!hasProse && !hasOutline && !reviewReportCount && !deconstructionCount) return;

  const sources = [];
  if (hasProse) sources.push('正文');
  if (hasOutline) sources.push('大纲');
  if (reviewReportCount) sources.push('追踪/审查报告');
  if (deconstructionCount) sources.push('拆文库');

  addCandidate(candidates, {
    id: 'legacy-project-recovery',
    workflow_type: hasProse || hasOutline ? 'legacy_long_recovery' : 'legacy_project_recovery',
    label: '恢复旧项目工作流断点（从元数据重建，需确认）',
    source: sources.join(', '),
    status: 'reconstructed',
    resume_hint: '/novel-assistant 恢复当前项目工作流断点',
    risk_level: 'medium',
    action: 'reconstruct_workflow_state',
    reconstructed: true,
  });
}

function buildInbox(projectRoot) {
  const root = path.resolve(projectRoot);
  const focused = readFocusedTask(root);
  if (focused.pointer && focused.authority.status !== 'ok') {
    return blockedTaskAuthorityInbox(root, focused.authority);
  }
  const migrationScan = scanWorkflowMigrations(root);
  const migrationInventory = visibleMigrationInventory(migrationScan.inventory);
  const hasVisibleMigration = migrationInventory.items.length > 0;
  if (focused.pointer && focused.authority.status === 'ok' && hasUnfinishedStatus(focused.authority.task.status)) {
    const validation = runStateValidation(root);
    if (String(validation.status || '') === 'blocked') {
      const reasonCode = String(validation.reason_code || '');
      if (hasVisibleMigration) {
        // Supported upstream/previous-version migration must be the first user
        // decision. Runtime guard repair belongs after migration acceptance.
      } else if (reasonCode === 'runtime_guard_missing' && focusedTaskBelongsToMultiBranchFamily(root, focused.authority.task)) {
        // A task family is the safer user-facing authority when multiple sessions
        // represent the same workflow. Do not let a single branch's legacy runtime
        // metadata hide the family recovery card.
      } else {
      return blockedStateValidationInbox(root, focused.authority.task, validation);
      }
    }
  }
  const candidates = [];
  const suppressedWorkflowIds = new Set(migrationInventory.items
    .filter(isMigrationSuppressed)
    .map(item => item.workflow_id)
    .filter(Boolean));
  const postCompletionRecommendations = scanWorkflowCompletion(root);

  scanMigrationCandidates(candidates, migrationInventory.items);
  const familyScan = scanTaskFamilies(root, candidates, suppressedWorkflowIds);
  for (const workflowId of familyScan.coveredWorkflowIds) suppressedWorkflowIds.add(workflowId);
  scanTaskDirectories(root, candidates, suppressedWorkflowIds);
  scanWorkflow(root, candidates, suppressedWorkflowIds);
  scanDownloadUpdate(root, candidates);
  if (!candidates.length) scanLegacyProjectHints(root, candidates);

  candidates.forEach((candidate, index) => {
    candidate.number = index + 1;
    candidate.display = `${index + 1}. ${candidate.label}`;
  });
  const taskCards = candidates.map((candidate, index) => buildTaskCard(candidate, index));
  const workflowGroups = buildWorkflowGroups(candidates);
  const migrationTaskCount = candidates.filter(candidate => candidate.migration).length;
  const shortProjectContext = isShortProjectContext(root, candidates);
  const lifecycleStatus = hasExistingProjectAssets(root) && !shortProjectContext ? buildLifecycleStatus(root) : null;
  const smartNewTaskRecommendations = deriveSmartNewTaskRecommendations(root, candidates, postCompletionRecommendations, lifecycleStatus);
  const newGoalOptions = deriveNewGoalOptions(root, candidates);

  return {
    schemaVersion: '1.0.0',
    startup_health_check: true,
    status: candidates.length ? 'has_tasks' : 'empty',
    project_root: root,
    focused_workflow_id: focused.authority.status === 'ok' ? String(focused.authority.task.workflow_id || '') : '',
    readPolicy: 'metadata_only',
    candidateCount: candidates.length,
    unfinished_family_count: familyScan.inventory.unfinished_family_count,
    task_families: familyScan.inventory.families,
    migration_task_count: migrationTaskCount,
    taskCardCount: taskCards.length,
    groupCount: workflowGroups.length,
    recommendationCount: postCompletionRecommendations.length,
    smartRecommendationCount: smartNewTaskRecommendations.length,
    candidates,
    task_cards: taskCards,
    workflow_groups: workflowGroups,
    smart_new_task_recommendations: smartNewTaskRecommendations,
    new_goal_options: newGoalOptions,
    default_visible_menu: workflowGroups.map((group) => group.display),
    flat_visible_menu: candidates.map((candidate) => candidate.display),
    task_visible_menu: taskCards.map((card) => card.display),
    visible_menu: workflowGroups.length ? workflowGroups.map((group) => group.display) : candidates.map((candidate) => candidate.display),
    post_completion_recommendations: postCompletionRecommendations,
    longform_lifecycle_status: lifecycleStatus,
    migration_inventory: migrationInventory,
    safe_default: '不自动继续旧任务；只展示可恢复任务，等待用户选择或提出新目标。',
  };
}

function blockedStateValidationInbox(root, task, validation) {
  const reasonCode = String(validation.reason_code || 'state_invariant');
  const title = blockedValidationTitle(reasonCode);
  const stopReason = blockedValidationStopReason(reasonCode, validation);
  const primaryAction = blockedValidationPrimaryAction(reasonCode, task, root);
  const identityFields = projectIdentityCandidateFields(root, task);
  const candidate = {
    ...identityFields,
    id: String((task || {}).workflow_id || 'focused-task'),
    workflow_type: String((task || {}).workflow_type || 'workflow_task'),
    label: title,
    title,
    visible_stage: reasonCode === 'pending_feedback_unreconciled' ? '处理待完成反馈' : '修复任务状态',
    scope_label: String((task || {}).scope || ''),
    last_trusted_artifact: extractTrustedArtifact(task),
    stop_reason: stopReason,
    next_actions: [
      {
        number: 1,
        label: primaryAction.label,
        action_id: primaryAction.action_id,
        risk_level: 'medium',
        requires_user_confirm: true,
        execution_command: primaryAction.execution_command || '',
      },
      { number: 2, label: '查看可恢复任务入口', action_id: 'show_task_inbox', risk_level: 'low' },
      { number: 3, label: '停止并保存断点', action_id: 'pause', risk_level: 'low' },
      { number: 4, label: '输入其他要求', action_id: 'free_text', risk_level: 'low' },
    ],
    free_text_enabled: true,
    source: 'workflow-state-validate.js',
    status: `blocked_${reasonCode}`,
    resume_hint: '',
    risk_level: 'medium',
    action: primaryAction.action_id,
    detail_lines: [
      ...(identityFields.detail_lines || []),
      ...blockedValidationDetails(reasonCode, validation),
    ],
  };
  const card = buildTaskCard(candidate, 0);
  return {
    schemaVersion: '1.0.0',
    startup_health_check: true,
    status: candidate.status,
    project_root: root,
    readPolicy: 'metadata_only',
    candidateCount: 1,
    unfinished_family_count: 0,
    task_families: [],
    migration_task_count: 0,
    taskCardCount: 1,
    groupCount: 0,
    recommendationCount: 0,
    smartRecommendationCount: 0,
    candidates: [candidate],
    task_cards: [card],
    workflow_groups: [],
    smart_new_task_recommendations: [],
    new_goal_options: [],
    default_visible_menu: [card.display],
    flat_visible_menu: [candidate.label],
    task_visible_menu: [card.display],
    visible_menu: [card.display],
    post_completion_recommendations: [],
    longform_lifecycle_status: null,
    migration_inventory: { items: [], summary: {} },
    state_validation: validation,
    safe_default: '当前焦点任务状态不一致，先修复任务账本，不自动继续旧阶段。',
  };
}

function blockedValidationTitle(reasonCode) {
  if (reasonCode === 'state_invariant') return '当前任务状态不一致，需先修复';
  if (reasonCode === 'stale_result_packet_scope') return '当前结果包属于旧小节，需先重新生成';
  if (reasonCode === 'pending_feedback_unreconciled') return '当前反馈尚未同步影响链，需先处理';
  if (reasonCode === 'trusted_artifact_missing') return '当前任务断点不完整，需先恢复';
  return '当前任务运行边界异常，需先修复';
}

function blockedValidationStopReason(reasonCode, validation) {
  const first = Array.isArray(validation.findings) ? validation.findings[0] : null;
  if (reasonCode === 'state_invariant') return '活动阶段、已完成阶段或结果包记录不一致；不能直接继续。';
  if (reasonCode === 'stale_result_packet_scope') return (first && first.message) || '检测到上一小节同名 result packet 残留；不能直接继续。';
  if (reasonCode === 'pending_feedback_unreconciled') return (first && first.message) || '存在未处理的用户反馈；不能直接继续。';
  if (reasonCode === 'trusted_artifact_missing') return '上次阶段的可信结果文件缺失；不能直接继续。';
  return '运行边界校验未通过；不能直接继续。';
}

function blockedValidationPrimaryAction(reasonCode, task, root) {
  if (reasonCode === 'stale_result_packet_scope') {
    return { label: '重新生成当前阶段结果包', action_id: 'regenerate_current_result_packet' };
  }
  if (reasonCode === 'pending_feedback_unreconciled') {
    return {
      label: '继续处理尚未完成的反馈',
      action_id: 'resume_feedback_impact_sync',
      execution_command: `node scripts/workflow-state-machine.js resume-pending-short-feedback --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(String((task || {}).workflow_id || ''))} --json`,
    };
  }
  if (reasonCode === 'trusted_artifact_missing') {
    return { label: '恢复任务断点', action_id: 'recover_missing_result_packet' };
  }
  return {
    label: reasonCode === 'state_invariant' ? '查看任务状态修复方案' : '修复当前 workflow 运行边界',
    action_id: reasonCode === 'state_invariant' ? 'repair_task_state' : 'repair_runtime_guard',
  };
}

function blockedValidationDetails(reasonCode, validation) {
  const lines = [];
  const first = Array.isArray(validation.findings) ? validation.findings[0] : null;
  if (first && first.message) lines.push(first.message);
  if (reasonCode === 'stale_result_packet_scope' && first) {
    lines.push(`期望：第 ${first.expected_section_index || '?'} 节；实际结果包：第 ${first.actual_section_index || '?'} 节。`);
  }
  if (reasonCode === 'trusted_artifact_missing') {
    lines.push('先恢复或重新生成上次阶段的可信结果文件，再回到可继续菜单；不会直接修改正文、大纲、细纲或设定。');
    return lines;
  }
  if (reasonCode === 'pending_feedback_unreconciled') {
    lines.push('反馈必须完成修订、复检和重新采用后才算关闭；不会重新分析全篇，也不会启动下一节。');
    return lines;
  }
  lines.push('先修复任务元数据或重新生成当前阶段结果包，再继续写作、审阅或拆文；不会直接修改正文、大纲、细纲或设定。');
  return lines;
}

function blockedTaskAuthorityInbox(root, authority) {
  return {
    schemaVersion: '1.0.0',
    startup_health_check: true,
    status: authority.status || 'blocked_task_authority_missing',
    project_root: root,
    readPolicy: 'metadata_only',
    candidateCount: 0,
    unfinished_family_count: 0,
    task_families: [],
    migration_task_count: 0,
    taskCardCount: 0,
    groupCount: 0,
    recommendationCount: 0,
    smartRecommendationCount: 0,
    candidates: [],
    task_cards: [],
    workflow_groups: [],
    smart_new_task_recommendations: [],
    new_goal_options: [],
    default_visible_menu: [],
    flat_visible_menu: [],
    task_visible_menu: [],
    visible_menu: [],
    post_completion_recommendations: [],
    longform_lifecycle_status: null,
    migration_inventory: { items: [], summary: {} },
    authority_error: authority.message || 'durable task snapshot is unavailable',
    safe_default: '焦点任务缺少可信快照，先修复任务权威再继续。',
  };
}

function writeInbox(root, inbox) {
  const dir = path.join(root, '追踪', 'workflow');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'task-index.json');
  fs.writeFileSync(file, `${JSON.stringify(inbox, null, 2)}\n`);
  return file;
}

function compactNextAction(action, projectRoot) {
  if (!action || typeof action !== 'object') return null;
  const resolution = action.action_resolution || {};
  const interactionMode = String(action.interaction_mode || '');
  const hasBoundSelection = Boolean(
    String(resolution.pending_action_id || '').trim()
      && String(resolution.visible_choice_hash || '').trim()
      && Number.isInteger(Number(resolution.state_version))
      && Number(resolution.state_version) > 0
  );
  const command = interactionMode === 'resume_stage'
    ? ''
    : action.execution_command
    ? materializeTaskCommand(action.execution_command, projectRoot)
    : ['pause', 'free_text'].includes(action.action_id)
      ? ''
      : action.action_id === 'show_task_inbox'
        ? 'node scripts/workflow-task-inbox.js --project-root . --json'
    : hasBoundSelection ? [
      'node scripts/workflow-state-machine.js resolve-action',
      '--project-root .',
      `--input ${Number(action.number) || 0}`,
      `--pending-action-id ${JSON.stringify(String(resolution.pending_action_id || ''))}`,
      `--visible-choice-hash ${JSON.stringify(String(resolution.visible_choice_hash || ''))}`,
      `--state-version ${Number(resolution.state_version) || 0}`,
      '--book-root .',
      '--json',
    ].join(' ') : '';
  return {
    number: action.number,
    label: action.label,
    action_id: action.action_id,
    target_stage: action.target_stage,
    risk_level: action.risk_level,
    action_resolution: resolution,
    execution_command: command,
    interaction_mode: interactionMode || (command ? 'execute_command' : 'semantic_only'),
    resume_hint: String(action.resume_hint || ''),
    stage_completion_command: String(action.stage_completion_command || ''),
  };
}

function materializeTaskCommand(command, projectRoot) {
  return String(command || '').replaceAll('<book-root>', '.');
}

function compactTaskCard(card, projectRoot) {
  if (!card || typeof card !== 'object') return null;
  return {
    number: card.number,
    id: card.id,
    workflow_type: card.workflow_type,
    title: card.title,
    visible_stage: card.visible_stage,
    scope_label: card.scope_label,
    last_trusted_artifact: card.last_trusted_artifact,
    stop_reason: card.stop_reason,
    status: card.status,
    risk_level: card.risk_level,
    task_family_id: card.task_family_id,
    head_workflow_id: card.head_workflow_id,
    project_id: card.project_id,
    working_title: card.working_title,
    project_status: card.project_status,
    task_overview_required: card.task_overview_required === true,
    free_text_enabled: card.free_text_enabled !== false,
    interaction_mode: card.interaction_mode || (card.execution_command ? 'execute_command' : 'semantic_only'),
    execution_command: materializeTaskCommand(card.execution_command, projectRoot),
    next_actions: (card.next_actions || []).map((action) => compactNextAction(action, projectRoot)).filter(Boolean),
    display: card.display,
  };
}

function isFocusedTaskCard(card, focusedWorkflowId) {
  const focused = String(focusedWorkflowId || '');
  if (!focused || !card) return false;
  return String(card.id || '') === focused || String(card.head_workflow_id || '') === focused;
}

function actionView(inbox, action) {
  if (!action || action === 'show_inbox') return inbox;
  const base = {
    schemaVersion: inbox.schemaVersion,
    status: action,
    project_root: inbox.project_root,
    readPolicy: inbox.readPolicy,
  };
  if (action === 'show_unfinished_tasks') {
    const taskCards = (inbox.task_cards || []).map((card) => compactTaskCard(card, inbox.project_root)).filter(Boolean);
    const focusedCard = taskCards.length === 1 && isFocusedTaskCard(taskCards[0], inbox.focused_workflow_id)
      ? taskCards[0]
      : null;
    if (focusedCard) {
      const projection = projectTaskActionView(focusedCard);
      return {
        ...base,
        status: 'current_task_actions',
        candidateCount: 1,
        taskCardCount: 1,
        focused_workflow_id: inbox.focused_workflow_id,
        selection_contract: 'execute_command_or_route_intent',
        ...projection,
        safe_default: '只执行用户选择的当前任务动作；不会自动开启其他任务。',
      };
    }
    return {
      ...base,
      candidateCount: inbox.candidateCount,
      taskCardCount: taskCards.length,
      task_cards: taskCards,
      selection_contract: 'execute_task_card_command_or_route_intent',
      visible_menu: taskCards.map((card) => card.display || `${card.number}. ${card.title}`),
      safe_default: inbox.safe_default,
    };
  }
  if (action === 'show_smart_recommendations') {
    return {
      ...base,
      recommendationCount: inbox.smartRecommendationCount,
      smart_new_task_recommendations: inbox.smart_new_task_recommendations,
      selection_contract: 'execute_recommendation_command_or_route_intent',
      visible_menu: (inbox.smart_new_task_recommendations || []).map((item) => item.display || `${item.number}. ${item.label}`),
    };
  }
  const newGoalOptions = (inbox.new_goal_options || []).map((item, index) => ({
    ...item,
    number: index + 1,
    interaction_mode: String(item.action || '').startsWith('free_text') ? 'semantic_only' : 'route_intent',
    route_intent: String(item.workflow_type || ''),
    preserve_existing_tasks: item.workflow_type !== 'free_text' && hasExistingProjectAssets(inbox.project_root),
    display: `${index + 1}. ${String(item.label || `选项 ${index + 1}`)}${item.description ? `\n   ${item.description}` : ''}`,
  }));
  return {
    ...base,
    new_goal_options: newGoalOptions,
    selection_contract: 'route_new_goal_or_accept_free_text',
    visible_menu: newGoalOptions.map((item) => item.display),
  };
}

function selectedView(view, selection) {
  const collections = [view.next_actions, view.task_cards, view.smart_new_task_recommendations, view.new_goal_options]
    .filter(Array.isArray);
  const selected = collections.flat().find((item) => Number(item.number) === Number(selection));
  return selected
    ? { schemaVersion: view.schemaVersion || '1.0.0', status: 'selection_ready', selected_number: Number(selection), selected }
    : { schemaVersion: view.schemaVersion || '1.0.0', status: 'selection_not_found', selected_number: Number(selection), visible_menu: view.visible_menu || [] };
}

function print(inbox, json, action = '', selection = 0) {
  const view = actionView(inbox, action);
  const output = selection ? selectedView(view, selection) : view;
  if (json) {
    console.log(JSON.stringify(output, null, 2));
    return;
  }
  if (selection) {
    if (output.status !== 'selection_ready') return console.log('该编号不在当前菜单中，请按最新的 1/2/3/4 选择。');
    console.log(output.selected.display || `${output.selected.number}. ${output.selected.title || output.selected.label}`);
    return;
  }
  if (action === 'show_unfinished_tasks') {
    if (view.status === 'current_task_actions') return console.log(view.visible_response);
    if (!view.task_cards.length) return console.log('未完成任务（0 个）。');
    console.log(`未完成任务（${view.candidateCount} 个）：`);
    for (const item of view.task_cards) console.log(item.display || `${item.number}. ${item.title || item.label}`);
    return;
  }
  if (action === 'show_smart_recommendations' || action === 'show_new_goal_options') {
    if (!view.visible_menu.length) return console.log('当前没有可展示的候选。');
    for (const line of view.visible_menu) console.log(line);
    return;
  }
  if (!inbox.candidates.length) {
    if (inbox.post_completion_recommendations.length) {
      console.log('上一个任务已完成，推荐下一步：');
      for (const item of inbox.post_completion_recommendations) console.log(`${item.number}. ${item.label}`);
      return;
    }
    console.log('工作流状态：没有发现可恢复任务。');
    return;
  }
  console.log('工作流入口：');
  console.log(`1. 查看未完成任务（${inbox.candidateCount} 个）`);
  console.log('2. 查看智能推荐新任务');
  console.log('3. 开启新的目标');
  console.log('4. 输入其他要求');
  console.log('回复数字选择。');
}

function main() {
  const args = parseArgs(process.argv);
  const inbox = buildInbox(args.projectRoot);
  if (args.write) {
    inbox.task_index_path = rel(path.resolve(args.projectRoot), writeInbox(path.resolve(args.projectRoot), inbox));
  }
  print(inbox, args.json, args.action, args.selection);
}

main();
