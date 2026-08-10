#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { acquireProjectLock, atomicWriteJson } = require('./lib/workflow-state-store');
const { mutateTaskAuthority, readFocusedTask } = require('./lib/workflow-task-authority');
const { resolveProjectRoot } = require('./lib/project-root-resolver');
const { isShortWorkflowType } = require('./lib/short-workflow-types');
// Lightweight project-internal helpers are required in-process instead of
// spawned, to avoid per-call node startup cost. Each module guards its CLI
// entry point with `if (require.main === module)` so requiring it is pure.
const { supervise } = require('./workflow-runtime-supervisor');
const { resolveAuthoritativeStatus } = require('./workflow-state-validate');
const { buildInbox, writeInbox } = require('./workflow-task-inbox');
const { resolveSessionId: resolveSessionIdFromModule } = require('./workflow-session-id');
const { previewMigration } = require('./task-family-migrate');
const {
  extractResumeScope,
  normalizeLegacyTaskAuthority,
  SCOPE_UNSPECIFIED,
} = require('./legacy-task-authority-recover');
const { classifyLegacyWorkflow } = require('./lib/legacy-workflow-type');
const workflowV3Compatibility = require('./lib/workflow-v3/compatibility-gateway');

const SCHEMA_VERSION = '1.0.0';
const USAGE = `Usage: node workflow-entry-guard.js --project-root <book-dir> [--visible-draft FILE] [--user-intent TEXT] [--session-id ID] [--takeover-session --confirm] [--write] [--compact] [--json]

Runs the mandatory startup guard for novel-assistant runners:
1. workflow-runtime-supervisor
2. workflow-task-inbox
3. optional visible reply output-pollution-check

It is intentionally deterministic and script-based so runners do not rely on
the model remembering to execute these gates from prose instructions.`;

function parseArgs(argv) {
  const args = {
    projectRoot: '',
    visibleDraft: '',
    userIntent: '',
    sessionId: '',
    takeoverSession: false,
    confirm: false,
    write: false,
    compact: false,
    json: false,
    selection: 0,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--visible-draft') args.visibleDraft = argv[++i] || '';
    else if (arg === '--user-intent') args.userIntent = argv[++i] || '';
    else if (arg === '--selection') args.selection = Number(argv[++i] || 0);
    else if (arg === '--session-id') args.sessionId = argv[++i] || '';
    else if (arg === '--takeover-session') args.takeoverSession = true;
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--write') args.write = true;
    else if (arg === '--compact') args.compact = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!args.projectRoot) args.projectRoot = process.cwd();
  if (args.selection && (!Number.isInteger(args.selection) || args.selection < 1)) fail('invalid --selection');
  if (!args.userIntent && args.selection) args.userIntent = String(args.selection);
  return args;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(2);
}

function runNode(scriptName, args) {
  const scriptPath = path.join(__dirname, scriptName);
  const result = spawnSync(process.execPath, [scriptPath, ...args], {
    encoding: 'utf8',
    shell: false,
  });
  return {
    status: result.status === null ? 1 : result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    error: result.error ? result.error.message : '',
  };
}

function parseJson(stdout, fallback) {
  try {
    return JSON.parse(stdout);
  } catch (error) {
    return {
      ...fallback,
      parse_error: error.message,
      raw_stdout: stdout.slice(0, 1000),
    };
  }
}

function runSupervisor(projectRoot) {
  try {
    const { exitCode, result } = supervise(projectRoot);
    return { exit_code: exitCode, result };
  } catch (error) {
    return {
      exit_code: 1,
      result: {
        status: 'blocked_supervisor_invalid_output',
        recommended_action: 'repair_runtime_guard',
        stderr: '',
        error: error.message,
      },
    };
  }
}

function readJsonFile(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function durableTaskSnapshotPath(task) {
  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'unknown-workflow'}`)
    .replace(/\\\\/g, '/')
    .replace(/\/$/, '');
  return `${taskDir}/task.json`;
}

function writeJsonFile(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}

function repairRuntimeGuard(projectRoot, supervisorResult) {
  const currentTaskPath = supervisorResult.current_task_path || path.join(projectRoot, '追踪', 'workflow', 'current-task.json');
  let release;
  try {
    release = acquireProjectLock(projectRoot, 'workflow-entry-guard:repair-runtime-guard');
    const focused = readFocusedTask(projectRoot);
    const task = focused.authority.status === 'ok' ? focused.authority.task : null;
    if (!task) {
      return { repaired: false, reason: 'current-task.json missing or invalid' };
    }
    const now = new Date().toISOString();
    task.runtime_guard = {
      heartbeat: {
        updated_at: now,
        latest_trusted_artifact: durableTaskSnapshotPath(task),
        workflow_id: task.workflow_id || '',
      },
      stall_policy: {
        heartbeat_timeout_minutes: 60,
        on_stall: 'pause_at_checkpoint',
      },
      checkpoint_policy: {
        resume_from: 'current_stage',
        checkpoint_path: durableTaskSnapshotPath(task),
        project_root: projectRoot,
      },
      token_cost_governance: {
        cost_summary_path: '追踪/workflow/token-cost-summary.json',
        ledger_path: '追踪/workflow/token-cost-ledger.jsonl',
      },
      auto_repaired_at: now,
      auto_repaired_reason: supervisorResult.reason || 'missing runtime_guard',
    };
    if (task.lifecycle && typeof task.lifecycle === 'object') task.lifecycle.updated_at = now;
    mutateTaskAuthority(projectRoot, task.workflow_id, Number(task.state_version || 0), () => task, { projectLockHeld: true, owner: 'workflow-entry-guard:repair-runtime-guard' });
    return { repaired: true, current_task_path: currentTaskPath, workflow_id: task.workflow_id || '' };
  } catch (error) {
    return { repaired: false, reason: error.code || error.message };
  } finally {
    if (release) release();
  }
}

function runStateValidation(projectRoot) {
  try {
    const result = resolveAuthoritativeStatus(projectRoot, {});
    return {
      exit_code: result.status === 'blocked' ? 2 : 0,
      result,
    };
  } catch (error) {
    return {
      exit_code: 1,
      result: {
        status: 'blocked_state_validation_invalid_output',
        stderr: '',
        error: error.message,
      },
    };
  }
}

function runTaskInbox(projectRoot, write) {
  try {
    const root = path.resolve(projectRoot);
    const inbox = buildInbox(projectRoot);
    if (write) {
      inbox.task_index_path = path.relative(root, writeInbox(root, inbox)).split(path.sep).join('/');
    }
    return { exit_code: 0, result: inbox };
  } catch (error) {
    return {
      exit_code: 1,
      result: {
        status: 'blocked_task_inbox_invalid_output',
        stderr: '',
        error: error.message,
      },
    };
  }
}

function isV3ShortTask(task) {
  return String((task || {}).workflow_type || '') === 'short_write'
    && Number((task || {}).engine_version) === 3
    && Number((task || {}).task_schema_version) === 3
    && Number((task || {}).workflow_contract_version) === 3;
}

function runV3Show(projectRoot, workflowId) {
  const child = runNode('workflow-v3.js', [
    'show',
    '--project-root', projectRoot,
    '--workflow-id', workflowId,
    '--json',
  ]);
  const output = parseJson(child.stdout, {
    ok: false,
    error: child.error || child.stderr || 'workflow-v3 show returned invalid JSON',
  });
  return { exit_code: child.status, result: output };
}

function runV3DescribeStage(projectRoot, workflowId) {
  const child = runNode('workflow-v3.js', [
    'describe-stage',
    '--project-root', projectRoot,
    '--workflow-id', workflowId,
    '--json',
  ]);
  const output = parseJson(child.stdout, {
    ok: false,
    error: child.error || child.stderr || 'workflow-v3 describe-stage returned invalid JSON',
  });
  return { exit_code: child.status, result: output };
}

function readPreviouslyDisplayedV3Binding(projectRoot, workflowId, sessionId) {
  const reportFile = path.join(projectRoot, '追踪', 'workflow', 'entry-guard.json');
  try {
    const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
    const binding = ((report.visible_response || {}).binding) || null;
    if (!['v3_task_ready', 'blocked_v3_binding_resolution'].includes(String(report.status || ''))
        || String(((report.session || {}).session_id) || '') !== String(sessionId || '')
        || !binding
        || String(binding.workflow_id || '') !== String(workflowId || '')) return null;
    const keys = Object.keys(binding).sort();
    const expected = ['pending_action_id', 'state_version', 'visible_choice_hash', 'workflow_id'];
    if (JSON.stringify(keys) !== JSON.stringify(expected)) return null;
    return binding;
  } catch (_) {
    return null;
  }
}

function runV3Resolve(projectRoot, workflowId, binding, choice) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-assistant-v3-resolve-'));
  const inputFile = path.join(tempDir, 'input.json');
  try {
    fs.writeFileSync(inputFile, `${JSON.stringify({ ...binding, choice })}\n`);
    const child = runNode('workflow-v3.js', [
      'resolve',
      '--project-root', projectRoot,
      '--workflow-id', workflowId,
      '--expected-version', String(binding.state_version),
      '--input-file', inputFile,
      '--json',
    ]);
    const output = parseJson(child.stdout, {
      ok: false,
      error: child.error || child.stderr || 'workflow-v3 resolve returned invalid JSON',
    });
    return { exit_code: child.status, result: output };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function runV3SubmitFeedback(projectRoot, workflowId, stateVersion, feedbackText) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-assistant-v3-feedback-'));
  const inputFile = path.join(tempDir, 'input.json');
  try {
    fs.writeFileSync(inputFile, `${JSON.stringify({ text: feedbackText })}\n`);
    const child = runNode('workflow-v3.js', [
      'submit-feedback',
      '--project-root', projectRoot,
      '--workflow-id', workflowId,
      '--expected-version', String(stateVersion),
      '--input-file', inputFile,
      '--json',
    ]);
    const output = parseJson(child.stdout, {
      ok: false,
      error: child.error || child.stderr || 'workflow-v3 submit-feedback returned invalid JSON',
    });
    return { exit_code: child.status, result: output };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function isDisplayedV3Choice(task, userIntent) {
  return Boolean(displayedV3ChoiceNumber(task, userIntent));
}

function displayedV3ChoiceNumber(task, userIntent) {
  const value = String(userIntent || '').trim();
  const options = (((task || {}).pending_action || {}).options) || [];
  if (/^\d+$/.test(value)) {
    const number = Number(value);
    return Number.isInteger(number) && number >= 1 && number <= options.length ? String(number) : '';
  }
  const option = options.find((item) => String((item || {}).label || '').trim() === value);
  return option ? String(option.number || options.indexOf(option) + 1) : '';
}

function isV3FreeTextFeedback(userIntent) {
  const value = String(userIntent || '').trim();
  if (!value || /^\d+$/.test(value)) return false;
  if (/^(?:继续(?:下一步|当前(?:任务|阶段|子任务))?|下一步|恢复|查看当前进度(?:与依据)?|暂停(?:并保存断点)?|输入其他要求)$/u.test(value)) {
    return false;
  }
  return true;
}

function isAcceptedV3PlanExecutionIntent(task, userIntent) {
  if (String((((task || {}).pending_feedback || {}).status) || '') !== 'accepted') return false;
  const value = String(userIntent || '').trim();
  if (!value) return false;
  if (value === 'apply_accepted_v3_feedback_plan') return true;
  return /(?:执行|应用|落实|落盘|回写|完成|推进|继续|恢复)(?:[^。；;\n]{0,24})(?:已|已经)(?:接受|采用|确认)(?:[^。；;\n]{0,12})(?:方案|计划)/u.test(value);
}

function isV3StageResumeIntent(userIntent) {
  return String(userIntent || '').trim() === '查看当前进度';
}

// V3 tasks bypass the V2 supervisor, reconciliation and menu builders. The
// compatibility gateway first proves that the focused task is a current V3
// authority; workflow-v3 show then supplies the only author-visible envelope.
function buildV3EntryReport(args, rootResolution) {
  const projectRoot = rootResolution.book_root;
  const session = resolveSessionId(args);
  const focused = readFocusedTask(projectRoot);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  if (!isV3ShortTask(task)) return null;

  const compatibility = workflowV3Compatibility.inspectCompatibility(projectRoot);
  if (compatibility.status !== 'current') {
    return {
      exitCode: 2,
      report: {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_v3_compatibility_check',
        recommended_next: 'repair_v3_task_authority',
        project_root: projectRoot,
        session,
        workflow_id: String(task.workflow_id || ''),
        compatibility,
        visible_response: null,
      },
    };
  }

  const workflowId = String(task.workflow_id || '');

  // A bare entry (no --user-intent) must always land
  // on the global task inbox, even when the focused V3 task has a pending
  // author interaction or a pending feedback lifecycle state. This is the
  // typical author startup view: it never leaks chapter/Brief stage wording
  // and keeps the global four-item menu as the single startup surface. The V3
  // interaction stays reachable behind option 1 (查看未完成任务).
  //
  // --write only controls durable metadata. It must not change the first screen.
  if (!String(args.userIntent || '').trim()) {
    const taskInbox = runTaskInbox(projectRoot, args.write);
    const outputGate = runVisibleOutputGate(args.visibleDraft ? path.resolve(args.visibleDraft) : '');
    const outputBlocked = outputGate.result.status === 'blocked_output_pollution';
    const report = {
      schemaVersion: SCHEMA_VERSION,
      status: outputBlocked ? 'blocked_output_pollution' : 'task_inbox_ready',
      workflow_id: workflowId,
      recommended_action: outputBlocked ? 'blocked_recovery_template' : 'show_task_inbox_only',
      next_action: outputBlocked ? 'blocked_recovery_template' : 'show_task_inbox_only',
      recommended_next: outputBlocked ? 'blocked_recovery_template' : 'show_task_inbox_only',
      project_root: projectRoot,
      session,
      root_resolution: rootResolution,
      compatibility,
      state_validation: {
        status: 'v3_authority_current',
        workflow_id: workflowId,
        current_stage: String(task.current_stage || ''),
      },
      task_inbox: taskInbox.result,
      output_gate: outputGate.result,
      runner_contract: {
        order: ['compatibility-gateway', 'workflow-task-inbox', 'output-pollution-check'],
        business_routing_allowed: false,
        show_task_inbox_only: !outputBlocked,
        metadata_only: true,
        v3_visible_authority: 'workflow-v3-show',
      },
      // Global four-item entry menu only; the V3 interaction stays behind
      // option 1 (查看未完成任务) until the author supplies an intent.
      visible_response: outputBlocked
        ? null
        : buildVisibleMenu('task_inbox_ready', taskInbox.result, '', projectRoot),
    };
    if (args.write) writeReport(projectRoot, report);
    return { exitCode: outputBlocked ? 2 : 0, report };
  }

  let shown = runV3Show(projectRoot, workflowId);
  if (shown.exit_code !== 0 || shown.result.ok !== true) {
    return {
      exitCode: 2,
      report: {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_v3_show',
        recommended_next: 'repair_v3_task_authority',
        project_root: projectRoot,
        session,
        workflow_id: String(task.workflow_id || ''),
        compatibility,
        v3_show: shown.result,
        visible_response: null,
      },
    };
  }

  let v3Resolution = null;
  let v3FeedbackReceipt = null;
  if (args.write
      && isV3FreeTextFeedback(args.userIntent)
      && !isDisplayedV3Choice(shown.result.task, args.userIntent)
      && !isAcceptedV3PlanExecutionIntent(shown.result.task, args.userIntent)) {
    const submitted = runV3SubmitFeedback(
      projectRoot,
      workflowId,
      Number((shown.result.task || {}).state_version),
      String(args.userIntent),
    );
    if (submitted.exit_code !== 0 || submitted.result.ok !== true) {
      return {
        exitCode: 2,
        report: {
          schemaVersion: SCHEMA_VERSION,
          status: 'blocked_v3_feedback_submission',
          recommended_next: 'show_current_v3_checkpoint',
          project_root: projectRoot,
          session,
          workflow_id: workflowId,
          compatibility,
          v3_feedback: submitted.result,
          visible_response: shown.result.interaction,
        },
      };
    }
    v3FeedbackReceipt = submitted.result.feedback_receipt || null;
    shown = runV3Show(projectRoot, workflowId);
    if (shown.exit_code !== 0 || shown.result.ok !== true) {
      return {
        exitCode: 2,
        report: {
          schemaVersion: SCHEMA_VERSION,
          status: 'blocked_v3_show_after_feedback',
          recommended_next: 'repair_v3_task_authority',
          project_root: projectRoot,
          session,
          workflow_id: workflowId,
          compatibility,
          feedback_receipt: v3FeedbackReceipt,
          visible_response: null,
        },
      };
    }
  } else if (args.write && shown.result.interaction && isDisplayedV3Choice(shown.result.task, args.userIntent)) {
    const displayedBinding = readPreviouslyDisplayedV3Binding(projectRoot, workflowId, session.session_id);
    if (displayedBinding) {
      const resolved = runV3Resolve(
        projectRoot,
        workflowId,
        displayedBinding,
        displayedV3ChoiceNumber(shown.result.task, args.userIntent),
      );
      if (resolved.exit_code !== 0 || resolved.result.ok !== true) {
        const refreshed = runV3Show(projectRoot, workflowId);
        const currentInteraction = refreshed.exit_code === 0 && refreshed.result.ok === true
          ? refreshed.result.interaction
          : shown.result.interaction;
        const blockedReport = {
          schemaVersion: SCHEMA_VERSION,
          status: 'blocked_v3_binding_resolution',
          recommended_next: 'show_current_v3_interaction',
          project_root: projectRoot,
          session,
          workflow_id: workflowId,
          compatibility,
          v3_resolution: resolved.result,
          // Refresh the durable displayed binding so the author's next reply
          // targets this current menu instead of retrying the stale one.
          visible_response: currentInteraction,
        };
        writeReport(projectRoot, blockedReport);
        return {
          exitCode: 2,
          report: blockedReport,
        };
      }
      v3Resolution = resolved.result.selection || null;
      shown = runV3Show(projectRoot, workflowId);
      if (shown.exit_code !== 0 || shown.result.ok !== true) {
        return {
          exitCode: 2,
          report: {
            schemaVersion: SCHEMA_VERSION,
            status: 'blocked_v3_show_after_resolution',
            recommended_next: 'repair_v3_task_authority',
            project_root: projectRoot,
            session,
            workflow_id: workflowId,
            compatibility,
            v3_show: shown.result,
            visible_response: null,
          },
        };
      }
    }
  }

  const taskInbox = runTaskInbox(projectRoot, args.write);
  const outputGate = runVisibleOutputGate(args.visibleDraft ? path.resolve(args.visibleDraft) : '');
  const outputBlocked = outputGate.result.status === 'blocked_output_pollution';
  const durableFeedback = (shown.result.task || {}).pending_feedback || null;
  const feedbackStatus = String((durableFeedback || {}).status || '');
  const feedbackState = v3FeedbackReceipt
    ? { status: 'v3_feedback_recorded', next: 'analyze_v3_feedback' }
    : !shown.result.interaction && feedbackStatus === 'pending_analysis'
      ? { status: 'v3_feedback_pending_analysis', next: 'analyze_v3_feedback' }
      : !shown.result.interaction && feedbackStatus === 'evidence_requested'
        ? { status: 'v3_feedback_evidence_requested', next: 'show_v3_feedback_evidence' }
        : !shown.result.interaction && feedbackStatus === 'accepted'
          ? { status: 'v3_feedback_plan_accepted', next: 'apply_accepted_v3_feedback_plan' }
          : !shown.result.interaction && feedbackStatus === 'paused'
            ? { status: 'v3_feedback_paused', next: 'keep_v3_feedback_checkpoint' }
            : null;
  const acceptedStage = feedbackState && feedbackState.status === 'v3_feedback_plan_accepted'
    ? runV3DescribeStage(projectRoot, workflowId)
    : null;
  const acceptedStageExecution = acceptedStage
    && acceptedStage.exit_code === 0
    && acceptedStage.result.ok === true
    ? acceptedStage.result.stage_execution
    : null;
  const resumedStage = !shown.result.interaction && !feedbackState && isV3StageResumeIntent(args.userIntent)
    ? runV3DescribeStage(projectRoot, workflowId)
    : null;
  const resumedStageExecution = resumedStage
    && resumedStage.exit_code === 0
    && resumedStage.result.ok === true
    ? resumedStage.result.stage_execution
    : null;
  const stageExecution = acceptedStageExecution || resumedStageExecution;
  const report = {
    schemaVersion: SCHEMA_VERSION,
    status: outputBlocked ? 'blocked_output_pollution' : feedbackState ? feedbackState.status : 'v3_task_ready',
    workflow_id: String(task.workflow_id || ''),
    recommended_action: feedbackState ? feedbackState.next : shown.result.interaction ? 'consume_v3_committed_binding' : stageExecution ? 'resume_current_v3_stage' : 'resume_unique_v3_checkpoint',
    next_action: feedbackState ? feedbackState.next : shown.result.interaction ? 'consume_v3_committed_binding' : stageExecution ? 'resume_current_v3_stage' : 'resume_unique_v3_checkpoint',
    recommended_next: feedbackState ? feedbackState.next : shown.result.interaction ? 'consume_v3_committed_binding' : stageExecution ? 'resume_current_v3_stage' : 'resume_unique_v3_checkpoint',
    project_root: projectRoot,
    session,
    root_resolution: rootResolution,
    compatibility,
    state_validation: {
      status: 'v3_authority_current',
      workflow_id: String(task.workflow_id || ''),
      current_stage: String(task.current_stage || ''),
    },
    task_inbox: taskInbox.result,
    output_gate: outputGate.result,
    v3_show: shown.result,
    v3_resolution: v3Resolution,
    feedback_receipt: v3FeedbackReceipt,
    ...(stageExecution ? {
      presentation_allowed: false,
      stage_execution: stageExecution,
    } : {}),
    runner_contract: {
      order: ['compatibility-gateway', 'workflow-v3-show', 'workflow-task-inbox', 'output-pollution-check'],
      business_routing_allowed: !outputBlocked && !shown.result.interaction && !feedbackState && !stageExecution,
      show_task_inbox_only: false,
      metadata_only: true,
      v3_visible_authority: 'workflow-v3-show',
    },
    // Do not wrap, copy or rebuild this object: it is the exact envelope from
    // renderCommittedInteraction via workflow-v3 show.
    visible_response: outputBlocked || feedbackState ? null : shown.result.interaction,
  };
  if (args.write) writeReport(projectRoot, report);
  return { exitCode: outputBlocked ? 2 : 0, report };
}

function previewTaskFamilyMigration(projectRoot) {
  const deployedFile = path.join(projectRoot, '.story-deployed');
  let raw = '';
  try { raw = fs.existsSync(deployedFile) ? fs.readFileSync(deployedFile, 'utf8').toLowerCase() : ''; } catch (_) { raw = ''; }
  const source = /oh-story|worldwonderer/.test(raw) ? 'oh-story' : /novel[-_]assistant/.test(raw) ? 'novel-assistant' : '';
  if (!source) return { exit_code: 0, result: { status: 'not_applicable', pending_task_count: 0 } };
  try {
    const { exitCode, result } = previewMigration(projectRoot, source);
    return { exit_code: exitCode, result };
  } catch (error) {
    return {
      exit_code: 1,
      result: { status: 'migration_preview_invalid', pending_task_count: 0, stderr: '', error: error.message },
    };
  }
}

function resolveSessionId(args) {
  if (args.sessionId) return { session_id: String(args.sessionId), source: 'argument' };
  try {
    return resolveSessionIdFromModule();
  } catch (_) {
    return { session_id: `process:${process.pid}`, source: 'entry_guard_fallback' };
  }
}

function currentWorkflowId(projectRoot) {
  const focused = readFocusedTask(projectRoot);
  return focused.authority.status === 'ok' ? String(focused.authority.task.workflow_id || '') : '';
}

function previewShortWorkflowMigration(projectRoot) {
  const compatibility = workflowV3Compatibility.inspectCompatibility(projectRoot);
  if (compatibility.status === 'current') {
    return { ...compatibility, required: false, safe_auto_migrate: false };
  }
  if (compatibility.status === 'safe_auto_upgrade') {
    return {
      ...compatibility,
      status: 'short_workflow_migration_pending',
      compatibility_status: 'safe_auto_upgrade',
      required: true,
      safe_auto_migrate: true,
      creative_assets_modified: false,
    };
  }
  if (compatibility.status === 'preview_required') {
    return {
      ...compatibility,
      status: 'short_workflow_migration_pending',
      compatibility_status: 'preview_required',
      required: true,
      safe_auto_migrate: false,
      creative_assets_modified: false,
    };
  }
  return { ...compatibility, status: 'not_applicable', required: false, safe_auto_migrate: false };
}

function autoMigrateShortWorkflow(projectRoot, migration) {
  if (!migration || migration.required !== true || migration.safe_auto_migrate !== true) {
    return { status: 'skipped', migrated: false };
  }
  const workflowId = String(migration.workflow_id || '');
  if (!workflowId) return { status: 'skipped_missing_workflow_id', migrated: false };
  const result = runNode('workflow-state-machine.js', [
    'migrate-short-lean-workflow',
    '--project-root', projectRoot,
    '--workflow-id', workflowId,
    '--confirm',
    '--json',
  ]);
  const parsed = parseJson(result.stdout, {
    status: 'short_workflow_auto_migration_failed',
    stderr: result.stderr,
    error: result.error,
  });
  return {
    ...parsed,
    migrated: result.status === 0
      && parsed.status === 'v3_migration_applied'
      && parsed.migrated !== false,
  };
}

function reconcileRuntime(projectRoot, workflowId, session, args) {
  if (!workflowId) return { exit_code: 0, result: { status: 'skipped_no_durable_workflow' } };
  const commandArgs = ['reconcile-runtime', '--project-root', projectRoot, '--workflow-id', workflowId, '--session-id', String(session.session_id || ''), '--json'];
  if (args.takeoverSession) commandArgs.push('--takeover');
  if (args.confirm) commandArgs.push('--confirm');
  const result = runNode('workflow-state-machine.js', commandArgs);
  return {
    exit_code: result.status,
    result: parseJson(result.stdout, { status: 'blocked_runtime_reconciliation_invalid_output', stderr: result.stderr, error: result.error }),
  };
}

function runVisibleOutputGate(visibleDraft) {
  if (!visibleDraft) {
    return {
      exit_code: 0,
      result: {
        status: 'skipped_no_visible_draft',
      },
    };
  }

  const result = runNode('output-pollution-check.js', [
    '--check',
    '--json',
    visibleDraft,
  ]);
  const parsed = parseJson(result.stdout, {
    findings: [],
    parse_error: 'output-pollution-check did not return JSON',
    stderr: result.stderr,
    error: result.error,
  });
  const findings = Array.isArray(parsed.findings) ? parsed.findings : [];
  return {
    exit_code: result.status,
    result: {
      status: findings.length > 0 ? 'blocked_output_pollution' : 'pass',
      visible_draft: visibleDraft,
      findings,
    },
  };
}

function isShortReply(text) {
  const value = String(text || '').trim();
  if (!value || Array.from(value).length > 16) return false;
  if (/^(确认|是|好|行|可以|继续|下一步|接着|暂停|跳过|取消|不|否|不用|先不|yes|y|ok|no|n|later|next|continue|pause|skip|cancel)$/i.test(value)) {
    return true;
  }
  if (/^(选)?第?[一二三四五六七八九十]+项?$/.test(value)) return true;
  return /^[0-9]+$/.test(value);
}

function isExplicitBusinessIntent(text) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (!value || isShortReply(value)) return false;
  const withoutCommand = value.replace(/^\/novel-assistant\s*/i, '').trim();
  if (!withoutCommand || isShortReply(withoutCommand)) return false;

  const explicitPatterns = [
    /反馈影响链/,
    /影响链检查/,
    /回写补丁/,
    /继续写/,
    /写第/,
    /开新书|新开长篇|新开短篇/,
    /短篇写作|开始短篇|写短篇/,
    /审阅|审查|复审|检查/,
    /回炉|重写|修订|修改/,
    /第\s*\d+\s*节[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/,
    /(?:开头|结尾|这一节)[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/,
    /拆文|拆书|扫榜|导入|去\s*AI|去AI|封面/,
  ];
  return explicitPatterns.some((pattern) => pattern.test(withoutCommand));
}

function isExplicitLegacyRecoveryIntent(text, workflowType = '') {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (!value || isShortReply(value)) return false;
  const explicit = isExplicitBusinessIntent(value)
    || /(?:继续|恢复).{0,12}第\s*\d+\s*(?:章|节|小节)/.test(value);
  if (!explicit) return false;
  return workflowType !== 'review_repair' || extractResumeScope(value) !== SCOPE_UNSPECIFIED;
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'"'"'`)}'`;
}

function portableProjectCommand(command, projectRoot) {
  let value = String(command || '');
  const root = String(projectRoot || '');
  if (!value || !root) return value;
  for (const token of [JSON.stringify(root), shellQuote(root), root]) {
    value = value.split(`--project-root ${token}`).join('--project-root .');
  }
  return value;
}

function shortFeedbackExecutionContractCurrent(task, execution) {
  if (String((task || {}).current_stage || '') !== 'feedback_impact_sync') return true;
  const expected = String((execution || {}).expected_result_packet || '');
  const writeSet = Array.isArray((execution || {}).write_set) ? execution.write_set.map(String) : [];
  const completion = String((execution || {}).stage_completion_command || (execution || {}).execution_command || '');
  return Boolean(expected
    && writeSet.length === 1
    && writeSet[0] === expected
    && /workflow-state-machine\.js apply-result/u.test(completion)
    && completion.includes(`--result ${JSON.stringify(expected)}`));
}

function shortFeedbackContractRecoveryIntent(task) {
  return {
    status: 'stage_contract_recovery_ready',
    intent_type: 'recover_running_feedback_contract',
    workflow_id: String((task || {}).workflow_id || ''),
    target_scope: String((task || {}).scope || ''),
    interaction_mode: 'execute_command',
    requires_user_confirm: false,
    preserves_completed_workflow_evidence: true,
    execution_workdir: '.',
    execution_command: `node scripts/workflow-state-machine.js resume-pending-short-feedback --project-root . --workflow-id ${JSON.stringify(String((task || {}).workflow_id || ''))} --json`,
  };
}

function runningStageIntent(task, projectRoot) {
  const execution = task && task.stage_execution && task.stage_execution.status === 'running'
    ? task.stage_execution
    : null;
  if (!execution) return null;
  if (!shortFeedbackExecutionContractCurrent(task, execution)) return shortFeedbackContractRecoveryIntent(task);
  const completionCommand = portableProjectCommand(
    execution.stage_completion_command || execution.execution_command,
    projectRoot,
  );
  const portableExecution = {
    ...execution,
    execution_workdir: '.',
    execution_command: completionCommand,
    quality_command: portableProjectCommand(execution.quality_command, projectRoot),
    stage_completion_command: completionCommand,
    current_required_action: 'edit_write_set',
    after_write_action: {
      type: 'execute_command',
      command: completionCommand,
    },
    completion_required_before_reply: true,
    context_read_command: portableProjectCommand(execution.context_read_command, projectRoot),
  };
  return {
    status: 'stage_execution_resume_ready',
    intent_type: 'resume_running_stage',
    workflow_id: String(task.workflow_id || ''),
    target_scope: String(task.scope || ''),
    interaction_mode: 'resume_stage',
    requires_user_confirm: false,
    preserves_completed_workflow_evidence: true,
    stage_execution: portableExecution,
    execution_workdir: '.',
    execution_command: portableExecution.execution_command || '',
    completion_required_before_reply: true,
    resume_hint: String(portableExecution.resume_hint || ''),
  };
}

function runningStageDisplayName(stageId, task = {}) {
  const names = {
    startup_scan: '检查短篇项目状态',
    freshness_window: '选择热点时间范围',
    info_source_pool: '抓取热点资讯',
    material_learning: '学习已选资讯',
    card_pool: '生成并筛选脑洞卡',
    topic_selection: '确认短篇选题',
    character_lock: '确认主要人物',
    plan_outline: '完善短篇设定与小节大纲',
    short_setting: '确认人物与剧情设定',
    platform_genre_lock: '锁定平台与题材方法',
    rhythm_pattern_selection: '锁定全篇节奏模式',
    section_outline: '生成全篇小节大纲',
    section_plan_lock: '确认总节数与小节标题',
    feedback_impact_sync: '分析反馈影响',
    feedback_apply_patch: '回写已确认的设定与小节大纲',
    first_section_brief: '生成第 1 节 Brief',
    section_brief: '生成当前小节 Brief',
    next_section_brief: '生成下一节 Brief',
    section_brief_ready: '生成当前小节写作提要',
    draft_first_section: '写第 1 节正文',
    draft_section: '写当前小节正文',
    draft_next_section: '写下一节正文',
    section_draft_loop: '写作当前小节',
    section_machine_gate: '检查当前小节格式与篇幅',
    quality_gate: '检查当前小节基础质量',
    story_value_gate: '检查当前小节故事价值',
    section_candidate_compare: '比较当前小节候选稿',
    section_accept_anchor: '采用当前小节并写入锚点',
    section_repair_loop: '修订当前小节',
    final_check: '完成全篇最终检查',
  };
  const normalized = String(stageId || '');
  if (normalized === 'info_source_pool') {
    const days = Number((((task || {}).freshness_window || {}).days) || 0);
    return days > 0 ? `抓取最近 ${days} 天热点资讯` : names[normalized];
  }
  return names[normalized] || '继续当前任务';
}

function runningTaskDisplayName(projectRoot, task) {
  if (!isShortWorkflowType((task || {}).workflow_type)) {
    return String((task || {}).user_goal || (task || {}).scope || '当前作品任务').trim();
  }
  const state = readJsonFile(path.join(projectRoot, '追踪', 'private-short-extension', 'project-state.json')) || {};
  const stored = String(
    state.working_title
    || state.title
    || ((state.selected_material || {}).label)
    || state.project_title
    || '',
  ).trim();
  if (stored) return stored.replace(/^《|》(?:设定(?:（第\s*\d+\s*版）)?|人物|世界观)?$/gu, '').trim();
  for (const [file, pattern] of [
    ['素材卡.md', /(?:暂定作品名|作品名|书名)\s*[：:]\s*[《「“"]?([^\n》」”"]+)[》」”"]?/u],
    ['设定.md', /^#\s*《([^》\n]+)》(?:设定|人物|世界观|$)/mu],
  ]) {
    try {
      const text = fs.readFileSync(path.join(projectRoot, file), 'utf8');
      const match = text.match(pattern);
      if (match && String(match[1] || '').trim()) return String(match[1]).trim();
    } catch (_) {
      // Fall back to the durable task label when the optional title source is absent.
    }
  }
  return String((task || {}).user_goal || (task || {}).scope || '当前作品任务').trim();
}

function buildRunningStageControls(projectRoot) {
  const focused = readFocusedTask(projectRoot);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  const execution = task && task.stage_execution && task.stage_execution.status === 'running'
    ? task.stage_execution
    : null;
  if (!task || !execution) return null;

  const stageName = runningStageDisplayName(execution.stage_id || task.current_stage, task);
  const resumeLabel = stageName.startsWith('继续') ? stageName : `继续${stageName}`;
  const command = (number) => `node scripts/workflow-state-machine.js resolve-action --project-root . --input ${number} --json`;
  const options = [
    numberedOption(1, resumeLabel, 'resume_running_stage', '从最后可信断点继续，不重复确认。', true),
    numberedOption(2, '查看当前进度与依据', 'inspect_running_stage', '只查看当前阶段、暂存目标和最后可信产物。'),
    numberedOption(3, '暂停并保存断点', 'pause_running_stage', '保留当前任务和暂存内容，稍后可以恢复。'),
    numberedOption(4, '输入其他要求', 'free_text', '补充意见、改范围或切换目标。'),
  ];
  options.slice(0, 3).forEach((option) => {
    option.interaction_mode = 'execute_command';
    option.execution_workdir = '.';
    option.execution_command = command(option.number);
  });
  const taskName = runningTaskDisplayName(projectRoot, task);
  const intro = `当前任务：${taskName}\n当前阶段：${stageName}`;
  return {
    render_mode: 'text_numbers',
    status: 'running_stage_waiting_choice',
    intro,
    workflow_id: String(task.workflow_id || ''),
    current_stage: String(execution.stage_id || task.current_stage || ''),
    options,
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择，也可以直接输入你的意见。`,
  };
}

function buildPendingShortStartupControls(projectRoot) {
  const focused = readFocusedTask(projectRoot);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  const pending = task && task.pending_action && typeof task.pending_action === 'object'
    ? task.pending_action
    : null;
  const currentStage = String((task || {}).current_stage || '');
  if (!task || !['startup_menu', 'freshness_window'].includes(currentStage) || !pending) return null;
  const pendingOptions = Array.isArray(pending.options) ? pending.options : [];
  if (pendingOptions.length === 0 || String(pending.status || '') === 'resolved') return null;

  const script = JSON.stringify(path.join(__dirname, 'workflow-state-machine.js'));
  const options = pendingOptions.slice(0, 4).map((item, index) => {
    const number = Number(item.number || index + 1);
    const option = numberedOption(
      number,
      item.label || `选项 ${number}`,
      item.action_id || '',
      item.description || '',
      Boolean(item.recommended)
    );
    if (String(item.action_id || '') === 'free_text') {
      option.interaction_mode = 'semantic_only';
    } else {
      option.interaction_mode = 'execute_command';
      option.execution_workdir = '.';
      option.execution_command = `node ${script} resolve-action --project-root . --input ${number} --bind-current --json`;
    }
    return option;
  });
  const intro = String(pending.question || '请选择短篇创作入口');
  return {
    render_mode: 'text_numbers',
    status: currentStage === 'startup_menu' ? 'short_startup_choice_required' : 'short_freshness_choice_required',
    intro,
    workflow_id: String(task.workflow_id || ''),
    current_stage: currentStage,
    options,
    selection_contract: 'execute_command_or_route_intent',
    command_execution_policy: 'verbatim_no_pipe_no_redirect_no_truncation',
    free_text_enabled: true,
    text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
  };
}

function isShortProject(projectRoot) {
  return ['素材卡.md', '设定.md', '小节大纲.md', '正文.md', '正文_新版.md']
    .filter((name) => fs.existsSync(path.join(projectRoot, name))).length >= 2;
}

function isShortRevisionIntent(text) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (!value) return false;
  return /(?:整篇|全篇|全文|通篇).{0,24}(?:修改|回炉|重写|修订)/.test(value)
    || /(?:修改|回炉|重写|修订).{0,24}(?:整篇|全篇|全文|通篇)/.test(value)
    || /第\s*\d+\s*节[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(value)
    || /(?:开头|结尾|这一节)[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(value);
}

function buildDirectIntent(projectRoot, userIntent) {
  if (!isShortProject(projectRoot) || !isShortRevisionIntent(userIntent)) return null;
  const focused = readFocusedTask(projectRoot);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  if (!task || !['short_write', 'short_startup', 'private_short_startup', 'short_revision'].includes(String(task.workflow_type || ''))) return null;
  const running = runningStageIntent(task, projectRoot);
  if (running) return running;
  return {
    status: 'ready',
    intent_type: 'short_revision_feedback',
    workflow_id: String(task.workflow_id || ''),
    target_scope: /(?:整篇|全篇|全文|通篇)/.test(String(userIntent || '')) ? '全篇' : String(task.scope || ''),
    interaction_mode: 'execute_command',
    requires_user_confirm: false,
    preserves_completed_workflow_evidence: true,
    execution_workdir: '.',
    execution_command: `node scripts/workflow-state-machine.js resolve-action --project-root . --input ${shellQuote(userIntent)} --json`,
  };
}

function hasAnyPath(projectRoot, relPaths) {
  return relPaths.some((relPath) => fs.existsSync(path.join(projectRoot, relPath)));
}

function hasNonEmptyCreativeDirectory(projectRoot, relPath) {
  const directory = path.join(projectRoot, relPath);
  try {
    return fs.statSync(directory).isDirectory() && fs.readdirSync(directory).length > 0;
  } catch (_) {
    return false;
  }
}

function hasDurableWorkflowTask(projectRoot) {
  const tasksDir = path.join(projectRoot, '追踪', 'workflow', 'tasks');
  try {
    return fs.readdirSync(tasksDir, { withFileTypes: true })
      .some((entry) => entry.isDirectory() && fs.existsSync(path.join(tasksDir, entry.name, 'task.json')));
  } catch (_) {
    return false;
  }
}

// Write-policy gate helpers (Task 3): legacy longform projects without a
// strict write policy must complete the strict write-policy migration before
// any task-authority or business routing decision is made. The strict_current
// condition is intentionally aligned with book-write-policy-migrate.js
// hasTransactionLedgers — policy mode=strict AND all four transaction ledgers
// on disk — so the gate cannot declare "strict_current" without the same
// evidence the migrator uses to apply the migration. Drift between these two
// checks would silently leak legacy routing past the gate.
function isStrictWritePolicyCurrent(projectRoot) {
  const policyFile = path.join(projectRoot, '追踪', 'story-system', 'write-policy.json');
  if (!fs.existsSync(policyFile)) return false;
  let policy;
  try {
    policy = JSON.parse(fs.readFileSync(policyFile, 'utf8'));
  } catch (_) {
    return false;
  }
  if (!policy || String(policy.mode || '') !== 'strict') return false;
  const storySystem = path.join(projectRoot, '追踪', 'story-system');
  return fs.existsSync(path.join(storySystem, 'transactions'))
    && fs.existsSync(path.join(storySystem, 'commits'))
    && fs.existsSync(path.join(storySystem, 'projection-log.jsonl'))
    && fs.existsSync(path.join(storySystem, 'chapter-identities.json'));
}

// classifyCurrentTaskPointer inspects 追踪/workflow/current-task.json and
// returns a structured descriptor so Gate 2 can choose the correct
// downstream shape:
//   { kind: 'absent' }                      — file is missing; downstream keeps the
//                                              normal authority path.
//   { kind: 'current', workflow_id }        — file carries a workflow_id; existing
//                                              authority owns it, no legacy gate.
//   { kind: 'recognized_legacy', task_id,
//     task_type }                           — safe legacy task_id note or the strict
//                                              type=outline_backfill allowlist shape;
//                                              primary option must offer the recovery
//                                              adapter command.
//   { kind: 'malformed_unrecognized',
//     reason }                              — file exists, no workflow_id, but the
//                                              body is unusable (parse error, not an
//                                              object, missing/unsafe task_id, or
//                                              unknown shape). Only a read-only /
//                                              semantic menu is allowed — no mutation
//                                              command, no repair_runtime_guard, no
//                                              legacy-task-authority-recover.
// Anything else (current durable path) is intentionally absent from this
// classifier so it falls through to the existing authority pipeline.
function classifyCurrentTaskPointer(projectRoot) {
  const focusPath = path.join(projectRoot, '追踪', 'workflow', 'current-task.json');
  if (!fs.existsSync(focusPath)) return { kind: 'absent', focus_path: focusPath };
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(focusPath, 'utf8'));
  } catch (error) {
    return { kind: 'malformed_unrecognized', focus_path: focusPath, reason: `current-task.json 不是合法 JSON：${error.message}` };
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { kind: 'malformed_unrecognized', focus_path: focusPath, reason: 'current-task.json 不是 JSON 对象，无法作为任务权威。' };
  }
  if (String(raw.workflow_id || '')) {
    return { kind: 'current', focus_path: focusPath, workflow_id: String(raw.workflow_id) };
  }
  const normalized = normalizeLegacyTaskAuthority(raw);
  if (!normalized.ok) {
    return { kind: 'malformed_unrecognized', focus_path: focusPath, reason: normalized.reason };
  }
  const classification = classifyLegacyWorkflow(normalized.task);
  if (classification.status !== 'supported') {
    return {
      kind: 'malformed_unrecognized',
      focus_path: focusPath,
      reason: `旧任务类型无法安全确认：${classification.reason}`,
    };
  }
  return {
    kind: 'recognized_legacy',
    focus_path: focusPath,
    task_id: normalized.task_id,
    task_type: normalized.task_type,
    workflow_type: classification.workflow_type,
  };
}

function isInitializedWritingProject(projectRoot) {
  // Runtime metadata is deliberately excluded: the entry guard writes it even
  // for a blank directory, so it cannot be evidence of an existing book.
  if (hasDurableWorkflowTask(projectRoot)) return true;
  if (hasAnyPath(projectRoot, [
    '素材卡.md',
    '设定.md',
    '小节大纲.md',
    '正文.md',
    '正文_新版.md',
    '.book-state.json',
  ])) return true;
  return [
    '正文',
    '大纲',
    '设定',
    '拆文库',
    '追踪/private-short-extension/cards',
  ].some((relPath) => hasNonEmptyCreativeDirectory(projectRoot, relPath));
}

function shouldBlockSupervisor(supervisor) {
  const status = String(supervisor.result.status || '');
  return supervisor.exit_code !== 0 || status === 'blocked';
}

function numberedOption(number, label, action, description = '', recommended = false) {
  const cleanLabel = String(label || '').replace(/（推荐）/gu, '').trim();
  const visibleLabel = recommended ? `${cleanLabel}（推荐）` : cleanLabel;
  return {
    number,
    label: visibleLabel,
    action,
    description,
    recommended,
    interaction_mode: ['pause', 'free_text', 'free_text_new_goal'].includes(action) ? 'semantic_only' : 'route_intent',
    display: `${number}. ${visibleLabel}`,
  };
}

function normalizeVisibleMenu(options, recommendedNumber = 1) {
  const list = (Array.isArray(options) ? options : []).slice(0, 4);
  return list.map((item, index) => ({
    ...item,
    ...numberedOption(
      index + 1,
      item.label,
      item.action,
      item.description,
      index + 1 === recommendedNumber
    ),
    execution_command: String(item.execution_command || ''),
    interaction_mode: item.interaction_mode || (item.execution_command ? 'execute_command' : undefined),
  }));
}

function taskActionResolutionMetadata(taskInbox) {
  const cards = Array.isArray((taskInbox || {}).task_cards) ? taskInbox.task_cards : [];
  const tasks = cards.map((card) => ({
    task_id: String(card.id || ''),
    action_resolution: card.action_resolution || null,
    options: (Array.isArray(card.next_actions) ? card.next_actions : []).map((option) => ({
      number: Number(option.number) || 0,
      action_resolution: option.action_resolution || card.action_resolution || null,
    })),
  })).filter((item) => item.action_resolution);
  return tasks.length ? { transport: 'structured_metadata', tasks } : null;
}

function buildWritePolicyMigrationVisibleResponse(projectRoot, intent) {
  const resumeIntent = String(intent || '').trim();
  const previewCommand = `node scripts/book-write-policy-migrate.js preview --project-root . --resume-intent ${shellQuote(resumeIntent)} --json`;
  const previewOption = numberedOption(
    1,
    '查看写入策略迁移预览',
    'preview_write_policy_migration',
    resumeIntent
      ? `使用原意图 ${resumeIntent} 生成本次写入策略迁移预览。`
      : '生成本次写入策略迁移预览，不写入任何内容。',
    true,
  );
  previewOption.interaction_mode = 'execute_command';
  previewOption.execution_workdir = '.';
  previewOption.execution_command = previewCommand;
  const inboxOption = numberedOption(
    2,
    '查看当前任务收件箱',
    'show_task_inbox',
    '只读查看现有任务与可信断点，不推进、不写入。',
  );
  inboxOption.interaction_mode = 'execute_command';
  inboxOption.execution_workdir = '.';
  inboxOption.execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
  const pauseOption = numberedOption(3, '暂停并保存断点', 'pause', '保持当前文件状态，稍后再处理写入策略迁移。');
  const freeTextOption = numberedOption(4, '输入其他要求', 'free_text', '说明要切换的目标、调整原意图或补充偏好。');
  const options = [previewOption, inboxOption, pauseOption, freeTextOption];
  const intro = '检测到当前书籍尚未启用严格写入策略：必须先完成写入策略预览/确认/应用，再继续原任务。';
  return {
    render_mode: 'text_numbers',
    status: 'write_policy_migration_required',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    intro,
    options,
    text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
  };
}

// Task 3 / Fixture B: after the strict write policy is current, a legacy
// `task_id` / `task_type` note with no workflow_id is the next gate. We
// MUST offer the legacy recovery adapter command (primary option,
// execute_command). We MUST NOT downgrade this to repair_runtime_guard.
// The malformed_unrecognized branch intentionally produces a smaller menu
// with only read-only / semantic options; no mutation command is allowed
// because we cannot safely target an unknown shape.
function buildLegacyTaskAuthorityRecoveryVisibleResponse(legacyNote, intent, projectRoot) {
  const resumeIntent = String(intent || '').trim();
  if (!legacyNote || legacyNote.kind === 'malformed_unrecognized') {
    const reason = String((legacyNote || {}).reason || 'current-task.json 无法识别为旧任务权威。');
    const inboxOption = numberedOption(
      1,
      '查看当前任务收件箱',
      'show_task_inbox',
      '只读查看现有任务与可信断点，不推进、不写入。',
    );
    inboxOption.interaction_mode = 'execute_command';
    inboxOption.execution_workdir = '.';
    inboxOption.execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
    const pauseOption = numberedOption(2, '暂停并保存断点', 'pause', '保留当前文件状态，稍后由人工确认后再处理。');
    const freeTextOption = numberedOption(3, '输入其他要求', 'free_text', '补充上下文、说明要切换的目标或要求人工接管。');
    const options = [inboxOption, pauseOption, freeTextOption];
    const intro = `检测到 current-task.json 但无法识别为旧任务权威：${reason}请先人工确认，不在此处继续写入。`;
    return {
      render_mode: 'text_numbers',
      status: 'blocked_task_authority_missing',
      selection_contract: 'route_intent_or_free_text',
      free_text_enabled: true,
      intro,
      options,
      text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择或直接说明你的要求。`,
    };
  }
  const recoveryIntentProvided = isExplicitLegacyRecoveryIntent(resumeIntent, legacyNote.workflow_type);
  const recoverOption = numberedOption(
    1,
    recoveryIntentProvided ? '恢复旧任务权威' : '说明本轮恢复目标',
    recoveryIntentProvided ? 'recover_legacy_task_authority' : 'provide_recovery_intent',
    recoveryIntentProvided
      ? `使用原意图 ${resumeIntent} 预览旧任务权威恢复，确认后由状态机接管。`
      : legacyNote.workflow_type === 'review_repair'
        ? '请直接说明审阅章节范围，例如“审阅第 1 至 3 章”；明确后才生成恢复预览。'
        : '请直接说明本轮要继续、修订或审阅的具体目标；明确后才生成恢复预览。',
    true,
  );
  if (recoveryIntentProvided) {
    recoverOption.interaction_mode = 'execute_command';
    recoverOption.execution_workdir = '.';
    recoverOption.execution_command = `node scripts/legacy-task-authority-recover.js preview --project-root . --resume-intent ${shellQuote(resumeIntent)} --json`;
  } else {
    recoverOption.interaction_mode = 'semantic_only';
    recoverOption.execution_command = '';
  }
  const inboxOption = numberedOption(
    2,
    '查看当前任务收件箱',
    'show_task_inbox',
    '只读查看现有任务与可信断点，不推进、不写入。',
  );
  inboxOption.interaction_mode = 'execute_command';
  inboxOption.execution_workdir = '.';
  inboxOption.execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
  const pauseOption = numberedOption(3, '暂停并保存断点', 'pause', '保留旧任务记录与当前目录，稍后再处理任务权威恢复。');
  const freeTextOption = numberedOption(4, '输入其他要求', 'free_text', '调整原任务的目的、范围或目标，重新生成恢复预览。');
  const options = [recoverOption, inboxOption, pauseOption, freeTextOption];
  const intro = recoveryIntentProvided
    ? `检测到旧任务权威（task_id=${legacyNote.task_id}）。下一步先完成预览/确认/应用，再继续原任务。`
    : legacyNote.workflow_type === 'review_repair'
      ? `检测到旧审阅任务（task_id=${legacyNote.task_id}），但尚未提供不可变章节范围。请直接说明例如“审阅第 1 至 3 章”；未明确前不会生成执行命令。`
      : `检测到旧任务权威（task_id=${legacyNote.task_id}），但尚未提供本轮恢复意图。请直接说明要继续、修订或审阅的具体目标；未明确前不会生成执行命令。`;
  return {
    render_mode: 'text_numbers',
    status: 'blocked_task_authority_missing',
    selection_contract: recoveryIntentProvided ? 'execute_command_or_route_intent' : 'route_intent_or_free_text',
    free_text_enabled: true,
    recovery_intent_required: !recoveryIntentProvided,
    intro,
    options,
    text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
  };
}

function buildWritePolicyMigrationReport(projectRoot, intent, session) {
  const visible = buildWritePolicyMigrationVisibleResponse(projectRoot, intent);
  const report = {
    schemaVersion: SCHEMA_VERSION,
    status: 'write_policy_migration_required',
    recommended_action: 'preview_or_confirm_write_policy_migration',
    next_action: 'preview_or_confirm_write_policy_migration',
    recommended_next: 'preview_or_confirm_write_policy_migration',
    project_root: projectRoot,
    session,
    supervisor: { status: 'skipped_pre_write_policy_migration' },
    state_validation: { status: 'skipped_pre_write_policy_migration', reason_code: 'write_policy_migration_required' },
    task_inbox: { status: 'skipped_pre_write_policy_migration' },
    task_family_migration: { status: 'skipped_pre_write_policy_migration', pending_task_count: 0 },
    short_workflow_migration: { status: 'not_applicable', required: false, safe_auto_migrate: false },
    short_workflow_auto_migration: { status: 'skipped_pre_write_policy_migration', migrated: false },
    output_gate: { status: 'skipped_no_visible_draft' },
    auto_repair: { repaired: false },
    runtime_reconciliation: { status: 'skipped_pre_write_policy_migration' },
    runner_contract: {
      order: ['write-policy-migration-preview'],
      business_routing_allowed: false,
      show_task_inbox_only: false,
      metadata_only: true,
    },
    visible_response: visible,
    legacy_status: { status: 'write_policy_migration_required' },
  };
  return { exitCode: 0, report };
}

function buildLegacyTaskAuthorityReport(projectRoot, legacyNote, intent, session) {
  const visible = buildLegacyTaskAuthorityRecoveryVisibleResponse(legacyNote, intent, projectRoot);
  const isMalformed = !legacyNote || legacyNote.kind === 'malformed_unrecognized';
  const recoveryIntentRequired = !isMalformed && visible.recovery_intent_required === true;
  const recommendedAction = isMalformed
    ? 'inspect_unrecognized_task_pointer'
    : (recoveryIntentRequired ? 'provide_recovery_intent' : 'recover_legacy_task_authority');
  const report = {
    schemaVersion: SCHEMA_VERSION,
    status: 'blocked_task_authority_missing',
    recommended_action: recommendedAction,
    next_action: recommendedAction,
    recommended_next: recommendedAction,
    project_root: projectRoot,
    session,
    supervisor: { status: 'blocked', recommended_action: recommendedAction, reason_code: 'task_authority_missing' },
    state_validation: { status: 'blocked', recommended_action: recommendedAction, reason_code: 'task_authority_missing' },
    task_inbox: { status: 'blocked_task_authority_missing' },
    task_family_migration: { status: 'skipped_pre_authority_recovery', pending_task_count: 0 },
    short_workflow_migration: { status: 'not_applicable', required: false, safe_auto_migrate: false },
    short_workflow_auto_migration: { status: 'skipped_pre_authority_recovery', migrated: false },
    output_gate: { status: 'skipped_no_visible_draft' },
    auto_repair: { repaired: false },
    runtime_reconciliation: { status: 'skipped_pre_authority_recovery' },
    runner_contract: {
      order: recoveryIntentRequired ? ['provide_recovery_intent'] : ['legacy-task-authority-recover'],
      business_routing_allowed: false,
      show_task_inbox_only: false,
      metadata_only: true,
    },
    visible_response: visible,
    legacy_status: isMalformed
      ? { status: 'blocked_task_authority_missing', pointer_kind: 'malformed_unrecognized', reason: String((legacyNote || {}).reason || '') }
      : { status: 'blocked_task_authority_missing', pointer_kind: 'recognized_legacy', legacy_task_id: String((legacyNote || {}).task_id || '') },
  };
  return { exitCode: 0, report };
}

function buildVisibleMenu(status, taskInbox, reasonCode = '', projectRoot = '', recoveryAction = null) {
  const options = [];
  if (status === 'blocked_workflow_session_lease') {
    const leaseOptions = normalizeVisibleMenu([
      numberedOption(1, '接管当前任务', 'takeover_workflow_session', '确认后由本会话继续；原会话转为只读，不会被终止。'),
      numberedOption(2, '只读查看当前任务', 'show_task_inbox_read_only', '查看任务与可信断点，不推进、不写入。'),
      numberedOption(3, '暂不接管', 'pause', '保留原写会话和当前断点。'),
      numberedOption(4, '输入其他要求', 'free_text', '说明要切换的目标或补充意见。'),
    ], 1);
    leaseOptions[0].execution_command = 'node scripts/workflow-entry-guard.js --project-root . --takeover-session --confirm --write --compact --json';
    leaseOptions[1].execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
    leaseOptions[0].execution_workdir = '.';
    leaseOptions[1].execution_workdir = '.';
    leaseOptions[0].interaction_mode = 'execute_command';
    leaseOptions[1].interaction_mode = 'execute_command';
    const intro = '当前任务正在另一会话中运行。为避免两边同时推进，本会话暂时只读。';
    return {
      render_mode: 'text_numbers',
      status,
      intro,
      options: leaseOptions,
      text: `${intro}\n\n${leaseOptions.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }
  if (status === 'new_project_ready') {
    const options = normalizeVisibleMenu([
      numberedOption(1, '新开长篇', 'create_workflow:long_startup', '先做题材定位、核心承诺、人物、剧情引擎、总纲、卷纲和前置细纲；不直接写正文。'),
      numberedOption(2, '新开短篇', 'create_workflow:short_write', '进入完整短篇生命周期；本地私有版自动加载资讯学习、素材池和卡片组合增强。'),
      numberedOption(3, '导入或拆文', 'create_workflow:import_or_deconstruction', '导入已有小说，或拆解对标文本形成可吸收技巧卡。'),
      numberedOption(4, '输入其他目标', 'free_text_new_goal', '直接说明你要扫榜、去 AI 味、做封面、迁移项目或其他任务。'),
    ], 0);
    options[1].execution_command = [
      'node', JSON.stringify(path.join(__dirname, 'short-startup-entry.js')),
      '--project-root', '.', '--json',
    ].join(' ');
    options[1].execution_workdir = '.';
    options[1].interaction_mode = 'execute_command';
    const intro = '当前目录还不是写作项目。请先选择要创建或导入的目标。';
    return {
      render_mode: 'text_numbers',
      status: 'new_project_ready',
      intro,
      options,
      text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }

  if (status === 'short_workflow_migration_pending') {
    const migration = taskInbox.short_workflow_migration || {};
    const workflowId = String(migration.workflow_id || '');
    const previewOnly = migration.compatibility_status === 'preview_required'
      || migration.safe_auto_migrate !== true;
    if (previewOnly) {
      const previewOption = numberedOption(
        1,
        '查看升级预览',
        'inspect_short_workflow_migration',
        '当前旧阶段无法安全自动续写。先只读查看可用证据、缺失信息和需要作者决定的恢复方向。',
        true,
      );
      previewOption.execution_command = `node scripts/workflow-state-machine.js migrate-short-lean-workflow --project-root . --workflow-id ${JSON.stringify(workflowId)} --json`;
      previewOption.execution_workdir = '.';
      previewOption.interaction_mode = 'execute_command';
      const inboxOption = numberedOption(
        2,
        '暂不升级，只读查看当前任务',
        'show_task_inbox_read_only',
        '保留旧任务与创作资产，不继续执行旧阶段。',
      );
      inboxOption.execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
      inboxOption.execution_workdir = '.';
      inboxOption.interaction_mode = 'execute_command';
      const freeTextOption = numberedOption(
        3,
        '输入其他要求',
        'free_text',
        '说明希望保留的阶段事实或本轮要恢复的具体目标。',
      );
      const migrationOptions = [previewOption, inboxOption, freeTextOption];
      const intro = '检测到旧版短篇任务，但其当前阶段无法安全映射到 V3。请先查看升级预览并由作者确认恢复方向；在确认前不会执行升级或改写创作资产。';
      return {
        render_mode: 'text_numbers',
        status,
        intro,
        options: migrationOptions,
        selection_contract: 'execute_command_or_route_intent',
        text: `${intro}\n\n${migrationOptions.map((option) => option.display).join('\n')}\n\n回复数字选择或直接说明你的要求。`,
      };
    }
    const migrationOptions = normalizeVisibleMenu([
      numberedOption(1, '升级并恢复当前短篇任务', 'migrate_short_workflow', '保留旧任务、暂存稿和历史回执；重建 workflow、memory 与阶段执行边界，不修改正文、设定或大纲。'),
      numberedOption(2, '查看升级预览', 'inspect_short_workflow_migration', '只查看将恢复的阶段、旧暂存稿和记忆处理方式，不写入。'),
      numberedOption(3, '暂不升级，只读查看当前任务', 'show_task_inbox_read_only', '不继续执行旧阶段，避免旧协议继续改写。'),
      numberedOption(4, '输入其他要求', 'free_text', '补充迁移范围、恢复偏好或新的目标。'),
    ], 1);
    migrationOptions[0].execution_command = `node scripts/workflow-state-machine.js migrate-short-lean-workflow --project-root . --workflow-id ${JSON.stringify(workflowId)} --confirm --json`;
    migrationOptions[1].execution_command = `node scripts/workflow-state-machine.js migrate-short-lean-workflow --project-root . --workflow-id ${JSON.stringify(workflowId)} --json`;
    migrationOptions[2].execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
    migrationOptions.slice(0, 3).forEach((option) => {
      option.interaction_mode = 'execute_command';
      option.execution_workdir = '.';
    });
    const intro = '检测到当前短篇任务仍使用旧版 workflow / memory 协议。继续旧阶段可能造成范围错位、重复校验或记忆上下文错误，需先升级任务账本。';
    return {
      render_mode: 'text_numbers',
      status,
      intro,
      options: migrationOptions,
      text: `${intro}\n\n${migrationOptions.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }

  if (status === 'task_inbox_ready') {
    const candidates = Array.isArray(taskInbox.candidates) ? taskInbox.candidates : [];
    const intro = '';

    options.push(numberedOption(1, `查看未完成任务（${candidates.length} 个）`, 'show_unfinished_tasks', '', candidates.length > 0));
    options.push(numberedOption(2, '查看智能推荐新任务', 'show_smart_recommendations', '', candidates.length === 0));
    options.push(numberedOption(3, '开启当前作品新目标', 'new_goal'));
    options.push(numberedOption(4, '输入其他要求', 'free_text'));
    options[0].execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_unfinished_tasks --json';
    options[1].execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_smart_recommendations --json';
    options[2].execution_command = 'node scripts/workflow-task-inbox.js --project-root . --action show_new_goal_options --json';
    options.slice(0, 3).forEach((option) => {
      option.interaction_mode = 'execute_command';
      option.execution_workdir = '.';
    });

    return {
      render_mode: 'text_numbers',
      status: 'task_inbox_ready',
      intro,
      options,
      action_resolution_metadata: taskActionResolutionMetadata(taskInbox),
      selection_contract: 'execute_command_or_route_intent',
      text: `${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }

  if (status === 'task_family_migration_pending') {
    const migrationOptions = normalizeVisibleMenu([
      numberedOption(1, '同步旧项目任务账本', 'migrate_task_families', '仅补 workflow/任务族元数据，不修改正文、大纲、细纲或设定。'),
      numberedOption(2, '查看迁移预览', 'show_task_family_migration_preview', '先查看将合并为同一任务的会话分支和潜在重叠。'),
      numberedOption(3, '暂不迁移，按旧兼容模式查看', 'show_task_inbox_legacy_compatible', '本次不写入迁移账本；后续仍会再次提醒。'),
      numberedOption(4, '输入其他要求', 'free_text', '可以改做写作、审阅、拆文或提出其他目标。'),
    ], 1);
    const intro = '检测到旧版写作项目的任务记录尚未迁移到任务族账本。先同步可避免多会话、暂停分支被重复计数。';
    return {
      render_mode: 'text_numbers', status, intro, options: migrationOptions,
      text: `${intro}\n\n${migrationOptions.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }

  if (String(status || '').startsWith('blocked_') || status === 'blocked' || status === 'stalled') {
    const inboxCard = Array.isArray(taskInbox.task_cards) ? taskInbox.task_cards[0] : null;
    if (inboxCard && String(inboxCard.status || '').startsWith('blocked_')) {
      const rawOptions = Array.isArray(inboxCard.next_actions)
        ? inboxCard.next_actions.map((action, index) => {
          const option = numberedOption(
            Number(action.number || index + 1),
            action.label || `选项 ${index + 1}`,
            action.action_id || action.action || '',
            action.description || ''
          );
          option.execution_command = String(action.execution_command || '');
          option.interaction_mode = option.execution_command
            ? 'execute_command'
            : ['pause', 'free_text'].includes(option.action)
              ? 'semantic_only'
              : 'route_intent';
          return option;
        })
        : [];
      const options = normalizeVisibleMenu(rawOptions, 1);
      const intro = inboxCard.stop_reason || inboxCard.title || '当前 workflow 被运行守卫暂停，需要先处理阻塞再继续。';
      const detailLines = [
        inboxCard.working_title ? `当前作品：${inboxCard.working_title}` : '',
        inboxCard.last_trusted_artifact ? `最后可信产物：${inboxCard.last_trusted_artifact}` : '',
      ].filter(Boolean);
      return {
        render_mode: 'text_numbers',
        status: inboxCard.status,
        intro,
        options,
        selection_contract: 'execute_command_or_route_intent',
        text: `${intro}${detailLines.length ? `\n${detailLines.join('\n')}` : ''}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
      };
    }
    const isMissingArtifact = reasonCode === 'trusted_artifact_missing' || status === 'blocked_trusted_artifact_missing';
    const isStateInvariant = reasonCode === 'state_invariant' || status === 'blocked_state_invariant';
    const isIncompleteCompleted = status === 'blocked_completed_workflow_incomplete';
    const recovery = recoveryAction && typeof recoveryAction === 'object' ? recoveryAction : null;
    const reason = String((recovery || {}).visible_reason || '') || (isMissingArtifact
      ? '当前任务断点不完整：上次阶段结果文件缺失。请先恢复断点，再继续当前任务。'
      : isStateInvariant
      ? '当前任务的活动状态与持久副本不一致，已停止自动修复，避免覆盖任一断点。请先归档旧断点并重建任务。'
      : isIncompleteCompleted
      ? '当前任务虽然被标记为已完成，但仍缺少必经阶段的可信回执。请先恢复缺失阶段，再继续收束。'
      : status === 'blocked_runtime_guard_missing'
      ? '当前 workflow 缺少运行边界，需要先修复断点账本。'
      : '当前 workflow 被运行守卫暂停，需要先处理阻塞再继续。');
    const recoveryActionId = String((recovery || {}).action_id || '');
    const recoveryLabel = recoveryActionId === 'resume_section_repair'
      ? '按质量反馈修订当前小节'
      : recoveryActionId === 'recover_task_authority'
        ? '说明要恢复的任务和范围'
        : recoveryActionId === 'inspect_blocker_details'
          ? '只读查看阻断依据'
          : isMissingArtifact ? '恢复任务断点' : isStateInvariant ? '查看任务状态修复方案' : isIncompleteCompleted ? '恢复未完整收束的任务' : '查看运行边界修复方案';
    const recoveryDescription = String((recovery || {}).visible_reason || '') || (
      isMissingArtifact ? '根据任务账本恢复上次阶段结果文件，然后回到可继续菜单。' : isStateInvariant ? '保留旧任务证据，归档后重建干净任务；不覆盖正文、大纲或报告。' : isIncompleteCompleted ? '只恢复缺失的 workflow 阶段与断点，不修改正文、大纲或审阅报告。' : '补齐 runtime_guard / heartbeat / checkpoint 后再继续。'
    );
    const options = normalizeVisibleMenu([
      numberedOption(
        1,
        recoveryLabel,
        recoveryActionId || (isMissingArtifact ? 'recover_missing_result_packet' : isStateInvariant ? 'repair_task_state' : isIncompleteCompleted ? 'restore_incomplete_workflow' : 'repair_runtime_guard'),
        recoveryDescription
      ),
      numberedOption(2, '查看可恢复任务入口', 'show_task_inbox', '只展示任务收件箱，不继续写正文或审阅。'),
      numberedOption(3, '停止并保存断点', 'pause', '保持当前文件状态，稍后再处理。'),
      numberedOption(4, '输入其他要求', 'free_text', '补充意见、纠偏、改范围或说明偏好都从这里进入。'),
    ], 1);
    if (isIncompleteCompleted) {
      const workflowId = String(taskInbox.focused_workflow_id || '');
      options[0].execution_command = `node scripts/workflow-state-machine.js restore-incomplete-workflow --project-root . --workflow-id ${JSON.stringify(workflowId)} --confirm --json`;
      options[0].execution_workdir = '.';
      options[0].interaction_mode = 'execute_command';
    } else if (recovery) {
      options[0].interaction_mode = String(recovery.interaction_mode || 'route_intent');
      if (String(recovery.execution_command || '')) {
        options[0].execution_command = String(recovery.execution_command);
        options[0].execution_workdir = '.';
      }
    }
    return {
      render_mode: 'text_numbers',
      status,
      intro: reason,
      options,
      selection_contract: 'execute_command_or_route_intent',
      text: `${reason}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
    };
  }

  return {
    render_mode: 'text_numbers',
    status,
    intro: '',
    options: [],
    text: '',
  };
}

function buildReport(args) {
  const rootResolution = resolveProjectRoot({ cwd: process.cwd(), explicitBookRoot: args.projectRoot });
  if (rootResolution.status !== 'resolved' || rootResolution.root_kind !== 'book') {
    return {
      exitCode: 2,
      report: {
        schemaVersion: SCHEMA_VERSION,
        status: 'blocked_project_root',
        recommended_next: 'select_one_book_directory',
        project_root: '',
        root_resolution: rootResolution,
        supervisor: { status: 'skipped_root_resolution' },
        state_validation: { status: 'skipped_root_resolution' },
        auto_repair: { repaired: false },
        task_inbox: { status: 'skipped_root_resolution' },
        output_gate: { status: 'skipped_root_resolution' },
        runner_contract: {
          order: [],
          business_routing_allowed: false,
          show_task_inbox_only: false,
          metadata_only: true,
        },
        visible_response: buildVisibleMenu('blocked_project_root', {}),
      },
    };
  }

  const projectRoot = rootResolution.book_root;
  const v3Entry = buildV3EntryReport(args, rootResolution);
  if (v3Entry) return v3Entry;
  const sessionEarly = resolveSessionId(args);
  // Task 3 / Gate 1: write-policy migration comes before any task-authority
  // or business routing decision. A project that already carries creative or
  // planning assets but lacks a strict write policy must complete the policy
  // migration first; the legacy task note is intentionally NOT inspected here
  // because it is meaningless until the policy is current.
  if (isInitializedWritingProject(projectRoot) && !isStrictWritePolicyCurrent(projectRoot)) {
    const policyReport = buildWritePolicyMigrationReport(projectRoot, args.userIntent || '', sessionEarly);
    if (args.write) writeReport(projectRoot, policyReport.report);
    return policyReport;
  }
  // Task 3 / Gate 2: after strict policy is current, classify the current-task
  // pointer. A recognized legacy pointer gets the recovery adapter only when
  // the user supplied an executable, type-valid recovery intent. Otherwise
  // it stays semantic/read-only; inventing an empty intent would silently
  // turn a prompt into a mutation. Malformed or unrecognized pointers carry
  // no recoverable shape, so they likewise surface only diagnostic actions.
  if (isStrictWritePolicyCurrent(projectRoot)) {
    const pointerShape = classifyCurrentTaskPointer(projectRoot);
    if (pointerShape.kind === 'recognized_legacy' || pointerShape.kind === 'malformed_unrecognized') {
      const legacyReport = buildLegacyTaskAuthorityReport(projectRoot, pointerShape, args.userIntent || '', sessionEarly);
      if (args.write) writeReport(projectRoot, legacyReport.report);
      return legacyReport;
    }
  }
  const explicitBusinessIntent = isExplicitBusinessIntent(args.userIntent);
  const projectInitialized = isInitializedWritingProject(projectRoot);
  const session = resolveSessionId(args);
  let supervisor = runSupervisor(projectRoot);
  let stateValidation = runStateValidation(projectRoot);
  let taskInbox = runTaskInbox(projectRoot, args.write);
  let taskFamilyMigration = previewTaskFamilyMigration(projectRoot);
  let shortWorkflowMigration = previewShortWorkflowMigration(projectRoot);
  let shortWorkflowAutoMigration = { status: args.write ? 'not_required' : 'skipped_read_only', migrated: false };
  let migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
  let runtimeReconciliation = { exit_code: 0, result: { status: args.write ? 'skipped_preflight' : 'skipped_read_only' } };
  let autoRepair = { repaired: false };
  if (args.write && shortWorkflowMigration.safe_auto_migrate === true) {
    shortWorkflowAutoMigration = autoMigrateShortWorkflow(projectRoot, shortWorkflowMigration);
    if (shortWorkflowAutoMigration.migrated) {
      const migratedV3Entry = buildV3EntryReport(args, rootResolution);
      if (migratedV3Entry) return migratedV3Entry;
      supervisor = runSupervisor(projectRoot);
      stateValidation = runStateValidation(projectRoot);
      taskInbox = runTaskInbox(projectRoot, true);
      taskFamilyMigration = previewTaskFamilyMigration(projectRoot);
      shortWorkflowMigration = previewShortWorkflowMigration(projectRoot);
      migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
    }
  }
  if (
    args.write
    && migrationTaskCount === 0
    && Number(taskFamilyMigration.result.pending_task_count) === 0
    && stateValidation.result.reason_code === 'runtime_guard_missing'
    && supervisor.result
    && supervisor.result.status === 'blocked'
    && supervisor.result.reason_code === 'runtime_guard_missing'
  ) {
    autoRepair = repairRuntimeGuard(projectRoot, supervisor.result);
    if (autoRepair.repaired) {
      supervisor = runSupervisor(projectRoot);
      stateValidation = runStateValidation(projectRoot);
      taskInbox = runTaskInbox(projectRoot, true);
      taskFamilyMigration = previewTaskFamilyMigration(projectRoot);
      shortWorkflowMigration = previewShortWorkflowMigration(projectRoot);
      migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
    }
  }
  if (
    args.write
    && migrationTaskCount === 0
    && shortWorkflowMigration.required !== true
    && String(stateValidation.result.status || '') !== 'blocked'
    && stateValidation.result.status !== 'migration_pending'
    && !shouldBlockSupervisor(supervisor)
  ) {
    runtimeReconciliation = reconcileRuntime(projectRoot, currentWorkflowId(projectRoot), session, args);
    if (runtimeReconciliation.exit_code === 0) {
      supervisor = runSupervisor(projectRoot);
      stateValidation = runStateValidation(projectRoot);
      taskInbox = runTaskInbox(projectRoot, true);
      taskFamilyMigration = previewTaskFamilyMigration(projectRoot);
      shortWorkflowMigration = previewShortWorkflowMigration(projectRoot);
      migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
    }
  }
  const outputGate = runVisibleOutputGate(args.visibleDraft ? path.resolve(args.visibleDraft) : '');
  const directIntent = explicitBusinessIntent ? buildDirectIntent(projectRoot, args.userIntent) : null;
  const runningStageControls = null;
  const pendingShortStartupControls = null;

  let status = 'pass';
  let recommendedNext = 'business_routing_allowed';
  let exitCode = 0;

  if (shortWorkflowMigration.required === true) {
    status = 'short_workflow_migration_pending';
    recommendedNext = 'preview_or_confirm_short_workflow_migration';
    exitCode = 0;
  } else if (['blocked_workflow_session_lease', 'workflow_session_takeover_required'].includes(String(runtimeReconciliation.result.status || ''))) {
    status = 'blocked_workflow_session_lease';
    recommendedNext = 'confirm_workflow_session_takeover';
    // A live lease is an expected user-choice state, not a shell failure.
    exitCode = 0;
  } else if (String(runtimeReconciliation.result.status || '') === 'blocked_completed_workflow_incomplete') {
    status = 'blocked_completed_workflow_incomplete';
    recommendedNext = 'restore_incomplete_workflow';
    // A damaged terminal marker has one explicit, confirmed recovery path.
    // Keep it user-visible instead of falling through to an empty task inbox.
    exitCode = 0;
  } else if (migrationTaskCount > 0) {
    status = 'task_inbox_ready';
    recommendedNext = 'show_task_inbox_only';
  } else if (Number(taskFamilyMigration.result.pending_task_count) > 0) {
    status = 'task_family_migration_pending';
    recommendedNext = 'preview_or_confirm_task_family_migration';
  } else if (String(stateValidation.result.status || '') === 'blocked') {
    status = 'blocked';
    recommendedNext = stateValidation.result.recommended_action || 'repair_task_state';
    // Pending short feedback has one deterministic recovery command. Returning
    // a non-zero exit here makes hosts label a normal menu as `Error` and then
    // encourages the model to guess unsupported flags.
    exitCode = ['state_invariant', 'pending_feedback_unreconciled'].includes(String(stateValidation.result.reason_code || ''))
      ? 0
      : stateValidation.exit_code || 2;
  } else if (stateValidation.result.status === 'migration_pending') {
    status = 'migration_pending';
    recommendedNext = stateValidation.result.recommended_action || 'migrate_legacy_review_and_continue';
  } else if (outputGate.result.status === 'blocked_output_pollution') {
    status = 'blocked_output_pollution';
    recommendedNext = 'blocked_recovery_template';
    exitCode = 2;
  } else if (shouldBlockSupervisor(supervisor)) {
    status = supervisor.result.status || 'blocked_supervisor';
    recommendedNext = supervisor.result.recommended_action || 'repair_runtime_guard';
    exitCode = supervisor.exit_code || 2;
  } else if (taskInbox.exit_code !== 0 || String(taskInbox.result.status || '').startsWith('blocked_')) {
    status = taskInbox.result.status || 'blocked_task_inbox';
    recommendedNext = 'repair_task_inbox';
    exitCode = taskInbox.exit_code || 2;
  } else if (!projectInitialized && !explicitBusinessIntent) {
    status = 'new_project_ready';
    recommendedNext = 'show_new_project_onboarding';
  } else if (projectInitialized && !explicitBusinessIntent) {
    status = 'task_inbox_ready';
    recommendedNext = 'show_task_inbox_only';
  }

  const showRunningStageControls = Boolean(
    runningStageControls && ['pass', 'task_inbox_ready'].includes(status)
  );
  const showPendingShortStartupControls = Boolean(
    pendingShortStartupControls && ['pass', 'task_inbox_ready'].includes(status)
  );
  if (showRunningStageControls) recommendedNext = 'show_running_stage_controls';
  else if (showPendingShortStartupControls) recommendedNext = 'show_short_startup_controls';

  const report = {
    schemaVersion: SCHEMA_VERSION,
    status,
    workflow_id: stateValidation.result.workflow_id || supervisor.result.workflow_id || '',
    recommended_action: recommendedNext,
    next_action: recommendedNext,
    recommended_next: recommendedNext,
    project_root: projectRoot,
    root_resolution: rootResolution,
    supervisor: supervisor.result,
    state_validation: stateValidation.result,
    session,
    runtime_reconciliation: runtimeReconciliation.result,
    auto_repair: autoRepair,
    task_inbox: taskInbox.result,
    task_family_migration: taskFamilyMigration.result,
    short_workflow_migration: shortWorkflowMigration,
    short_workflow_auto_migration: shortWorkflowAutoMigration,
    output_gate: outputGate.result,
    direct_intent: directIntent,
    runner_contract: {
      order: [
        'workflow-runtime-reconciliation',
        'workflow-runtime-supervisor',
        'workflow-task-inbox',
        'output-pollution-check',
      ],
      business_routing_allowed: status === 'pass',
      show_task_inbox_only: status === 'task_inbox_ready' && !showRunningStageControls && !showPendingShortStartupControls,
      metadata_only: true,
      migration_task_count: migrationTaskCount,
      task_family_migration_pending_count: Number(taskFamilyMigration.result.pending_task_count) || 0,
      project_initialized: projectInitialized,
      user_intent_present: String(args.userIntent || '').trim() !== '',
      explicit_business_intent: explicitBusinessIntent,
      task_inbox_deferred_for_explicit_intent: explicitBusinessIntent && status === 'pass' && ((Number(taskInbox.result.candidateCount) || 0) > 0 || (Number(taskInbox.result.recommendationCount) || 0) > 0),
    },
  };
  report.task_inbox = {
    ...report.task_inbox,
    short_workflow_migration: shortWorkflowMigration,
    short_workflow_auto_migration: shortWorkflowAutoMigration,
  };
  if (status === 'pass' && directIntent && directIntent.interaction_mode === 'resume_stage') {
    report.presentation_allowed = false;
  }
  report.visible_response = status === 'pass' && directIntent
    ? {
      render_mode: directIntent.interaction_mode === 'resume_stage' ? 'silent_resume' : 'silent_execute',
      status: directIntent.status === 'stage_execution_resume_ready' ? directIntent.status : 'explicit_intent_ready',
      ...(directIntent.interaction_mode === 'resume_stage' ? { user_visible: false } : { text: '' }),
      selection_contract: directIntent.interaction_mode === 'resume_stage' ? 'resume_running_stage' : 'execute_direct_intent_command',
      interaction_mode: directIntent.interaction_mode,
      execution_workdir: '.',
      execution_command: directIntent.execution_command,
      resume_hint: directIntent.resume_hint || '',
      stage_execution: directIntent.stage_execution || null,
      requires_user_confirm: false,
      completion_required_before_reply: directIntent.completion_required_before_reply === true,
    }
    : showRunningStageControls
      ? runningStageControls
      : showPendingShortStartupControls
        ? pendingShortStartupControls
      : buildVisibleMenu(
        status,
        report.task_inbox,
        stateValidation.result.reason_code || '',
        projectRoot,
        stateValidation.result.recovery_action || null,
      );
  if (status === 'migration_pending') {
    report.task_inbox_presentation = {
      status: 'task_inbox_ready',
      recommended_next: 'show_task_inbox_only',
    };
  }
  if (status === 'blocked') {
    report.legacy_status = {
      status: `blocked_${stateValidation.result.reason_code || 'runtime_guard'}`,
    };
  }

  if (args.write) writeReport(projectRoot, report);
  return { exitCode, report };
}

function writeReport(projectRoot, report) {
  const workflowDir = path.join(projectRoot, '追踪', 'workflow');
  fs.mkdirSync(workflowDir, { recursive: true });
  fs.writeFileSync(path.join(workflowDir, 'entry-guard.json'), JSON.stringify(report, null, 2));
}

function print(report, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
    return;
  }
  console.log(`${report.status}: ${report.recommended_next}`);
  console.log(`supervisor: ${report.supervisor.status || 'unknown'} -> ${report.supervisor.recommended_action || ''}`);
  console.log(`task_inbox: ${report.task_inbox.status || 'ok'}`);
  console.log(`output_gate: ${report.output_gate.status}`);
}

function compactStageExecution(execution) {
  if (!execution || typeof execution !== 'object') return null;
  const packet = execution.stage_context_packet && typeof execution.stage_context_packet === 'object'
    ? execution.stage_context_packet
    : {};
  return {
    status: String(execution.status || ''),
    selection_contract: String(execution.selection_contract || ''),
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    stage_id: String(execution.stage_id || ''),
    step_id: String(execution.step_id || ''),
    owner_module: String(execution.owner_module || ''),
    write_set: Array.isArray(execution.write_set) ? execution.write_set : [],
    source_files: Array.isArray(execution.source_files) ? execution.source_files : [],
    section_index: Number(execution.section_index) || 0,
    expected_result_packet: String(execution.expected_result_packet || ''),
    execution_workdir: String(execution.execution_workdir || '.'),
    execution_command: String(execution.execution_command || ''),
    quality_command: String(execution.quality_command || ''),
    stage_completion_command: String(execution.stage_completion_command || ''),
    current_required_action: String(execution.current_required_action || ''),
    after_write_action: execution.after_write_action && typeof execution.after_write_action === 'object'
      ? execution.after_write_action
      : null,
    completion_required_before_reply: execution.completion_required_before_reply === true,
    context_read_command: String(execution.context_read_command || ''),
    resume_hint: String(execution.resume_hint || ''),
    stage_context_packet: packet.packet_md || packet.packet_json
      ? {
        packet_md: String(packet.packet_md || ''),
        packet_json: String(packet.packet_json || ''),
        section_index: Number(packet.section_index) || 0,
        estimated_tokens: Number(packet.estimated_tokens) || 0,
      }
      : null,
  };
}

function compactDirectIntent(directIntent) {
  if (!directIntent || typeof directIntent !== 'object') return null;
  const compact = {
    status: String(directIntent.status || ''),
    intent_type: String(directIntent.intent_type || ''),
    workflow_id: String(directIntent.workflow_id || ''),
    target_scope: String(directIntent.target_scope || ''),
    interaction_mode: String(directIntent.interaction_mode || ''),
    requires_user_confirm: Boolean(directIntent.requires_user_confirm),
    execution_workdir: String(directIntent.execution_workdir || '.'),
    execution_command: String(directIntent.execution_command || ''),
    resume_hint: String(directIntent.resume_hint || ''),
  };
  if (compact.interaction_mode === 'resume_stage') {
    delete compact.execution_command;
    delete compact.resume_hint;
  }
  return compact;
}

function compactVisibleResponse(visibleResponse) {
  if (!visibleResponse || typeof visibleResponse !== 'object') return null;
  if (typeof visibleResponse.text === 'string'
      && visibleResponse.binding
      && !Object.prototype.hasOwnProperty.call(visibleResponse, 'stage_execution')) {
    return visibleResponse;
  }
  const compact = {
    ...visibleResponse,
    stage_execution: compactStageExecution(visibleResponse.stage_execution),
  };
  if (compact.interaction_mode === 'resume_stage' && compact.stage_execution) {
    delete compact.execution_command;
    delete compact.resume_hint;
  }
  return compact;
}

function compactReport(report) {
  const reconciliation = report.runtime_reconciliation || {};
  const validation = report.state_validation || {};
  const inbox = report.task_inbox || {};
  return {
    schemaVersion: report.schemaVersion,
    status: report.status,
    recommended_next: report.recommended_next,
    presentation_allowed: report.presentation_allowed !== false,
    project_root: report.project_root,
    workflow_id: report.workflow_id || validation.workflow_id || '',
    current_stage: validation.current_stage || '',
    session: report.session || null,
    runtime_reconciliation: {
      status: reconciliation.status || '',
      findings: reconciliation.findings || [],
    },
    task_inbox_summary: {
      status: inbox.status || '',
      candidateCount: Number(inbox.candidateCount) || 0,
      smartRecommendationCount: Number(inbox.smartRecommendationCount) || 0,
    },
    short_workflow_auto_migration: report.short_workflow_auto_migration || null,
    feedback_receipt: report.feedback_receipt || null,
    stage_execution: compactStageExecution(report.stage_execution),
    runner_contract: {
      business_routing_allowed: Boolean((report.runner_contract || {}).business_routing_allowed),
      show_task_inbox_only: Boolean((report.runner_contract || {}).show_task_inbox_only),
    },
    direct_intent: compactDirectIntent(report.direct_intent),
    visible_response: compactVisibleResponse(report.visible_response),
  };
}

function main() {
  const args = parseArgs(process.argv);
  const { exitCode, report } = buildReport(args);
  print(args.compact ? compactReport(report) : report, args.json);
  // Let Node drain stdout before exiting. Calling process.exit() immediately
  // after stdout.write() truncates JSON larger than the pipe buffer (64 KiB),
  // which is common for migrated projects carrying a long task history.
  process.exitCode = exitCode;
}

main();
