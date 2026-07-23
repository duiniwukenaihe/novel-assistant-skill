#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { acquireProjectLock, atomicWriteJson } = require('./lib/workflow-state-store');
const { mutateTaskAuthority, readFocusedTask } = require('./lib/workflow-task-authority');
const { resolveProjectRoot } = require('./lib/project-root-resolver');

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
  const result = runNode('workflow-runtime-supervisor.js', [
    '--project-root',
    projectRoot,
    '--json',
  ]);
  return {
    exit_code: result.status,
    result: parseJson(result.stdout, {
      status: 'blocked_supervisor_invalid_output',
      recommended_action: 'repair_runtime_guard',
      stderr: result.stderr,
      error: result.error,
    }),
  };
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
  const result = runNode('workflow-state-validate.js', ['--project-root', projectRoot, '--json']);
  return {
    exit_code: result.status,
    result: parseJson(result.stdout, {
      status: 'blocked_state_validation_invalid_output',
      stderr: result.stderr,
      error: result.error,
    }),
  };
}

function runTaskInbox(projectRoot, write) {
  const args = ['--project-root', projectRoot, '--json'];
  if (write) args.push('--write');
  const result = runNode('workflow-task-inbox.js', args);
  return {
    exit_code: result.status,
    result: parseJson(result.stdout, {
      status: 'blocked_task_inbox_invalid_output',
      stderr: result.stderr,
      error: result.error,
    }),
  };
}

function previewTaskFamilyMigration(projectRoot) {
  const deployedFile = path.join(projectRoot, '.story-deployed');
  let raw = '';
  try { raw = fs.existsSync(deployedFile) ? fs.readFileSync(deployedFile, 'utf8').toLowerCase() : ''; } catch (_) { raw = ''; }
  const source = /oh-story|worldwonderer/.test(raw) ? 'oh-story' : /novel[-_]assistant/.test(raw) ? 'novel-assistant' : '';
  if (!source) return { exit_code: 0, result: { status: 'not_applicable', pending_task_count: 0 } };
  const result = runNode('task-family-migrate.js', ['--project-root', projectRoot, '--source', source, '--json']);
  return {
    exit_code: result.status,
    result: parseJson(result.stdout, { status: 'migration_preview_invalid', pending_task_count: 0, stderr: result.stderr, error: result.error }),
  };
}

function resolveSessionId(args) {
  if (args.sessionId) return { session_id: String(args.sessionId), source: 'argument' };
  const result = runNode('workflow-session-id.js', ['--json']);
  return parseJson(result.stdout, { session_id: `process:${process.pid}`, source: 'entry_guard_fallback' });
}

function currentWorkflowId(projectRoot) {
  const focused = readFocusedTask(projectRoot);
  return focused.authority.status === 'ok' ? String(focused.authority.task.workflow_id || '') : '';
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

function runningStageIntent(task, projectRoot) {
  const execution = task && task.stage_execution && task.stage_execution.status === 'running'
    ? task.stage_execution
    : null;
  if (!execution) return null;
  const portableExecution = {
    ...execution,
    execution_workdir: '.',
    execution_command: portableProjectCommand(execution.execution_command, projectRoot),
    quality_command: portableProjectCommand(execution.quality_command, projectRoot),
    stage_completion_command: portableProjectCommand(execution.stage_completion_command, projectRoot),
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
    resume_hint: String(portableExecution.resume_hint || ''),
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

function buildRunningStageControls(projectRoot) {
  const focused = readFocusedTask(projectRoot);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  const execution = task && task.stage_execution && task.stage_execution.status === 'running'
    ? task.stage_execution
    : null;
  if (!task || !execution) return null;

  const command = (number) => `node scripts/workflow-state-machine.js resolve-action --project-root . --input ${number} --json`;
  const options = [
    numberedOption(1, '继续当前阶段', 'resume_running_stage', '从最后可信断点继续，不重复确认。', true),
    numberedOption(2, '查看当前进度与依据', 'inspect_running_stage', '只查看当前阶段、暂存目标和最后可信产物。'),
    numberedOption(3, '暂停并保存断点', 'pause_running_stage', '保留当前任务和暂存内容，稍后可以恢复。'),
    numberedOption(4, '输入其他要求', 'free_text', '补充意见、改范围或切换目标。'),
  ];
  options.slice(0, 3).forEach((option) => {
    option.interaction_mode = 'execute_command';
    option.execution_workdir = '.';
    option.execution_command = command(option.number);
  });
  const stageName = runningStageDisplayName(execution.stage_id || task.current_stage);
  const intro = `当前任务停在“${stageName}”阶段。`;
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

function normalizeFourMenu(options, recommendedNumber = 1) {
  const list = (Array.isArray(options) ? options : []).slice(0, 4);
  const actions = new Set(list.map((item) => String(item.action || '')));
  if (list.length < 4 && !actions.has('show_task_inbox')) list.push(numberedOption(0, '查看当前任务', 'show_task_inbox'));
  if (list.length < 4 && !actions.has('pause')) list.push(numberedOption(0, '暂停并保存断点', 'pause'));
  if (list.length < 4 && !actions.has('free_text')) list.push(numberedOption(0, '输入其他要求', 'free_text'));
  while (list.length < 4) list.push(numberedOption(0, '返回任务列表', 'show_task_inbox'));
  return list.slice(0, 4).map((item, index) => ({
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

function buildVisibleMenu(status, taskInbox, reasonCode = '', projectRoot = '') {
  const options = [];
  if (status === 'blocked_workflow_session_lease') {
    const leaseOptions = normalizeFourMenu([
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
    const options = normalizeFourMenu([
      numberedOption(1, '新开长篇', 'create_workflow:long_startup', '先做题材定位、核心承诺、人物、剧情引擎、总纲、卷纲和前置细纲；不直接写正文。'),
      numberedOption(2, '新开短篇', 'create_workflow:short_write', '进入完整短篇生命周期；本地私有版自动加载资讯学习、素材池和卡片组合增强。'),
      numberedOption(3, '导入或拆文', 'create_workflow:import_or_deconstruction', '导入已有小说，或拆解对标文本形成可吸收技巧卡。'),
      numberedOption(4, '输入其他目标', 'free_text_new_goal', '直接说明你要扫榜、去 AI 味、做封面、迁移项目或其他任务。'),
    ], 0);
    const intro = '当前目录还不是写作项目。请先选择要创建或导入的目标。';
    return {
      render_mode: 'text_numbers',
      status: 'new_project_ready',
      intro,
      options,
      text: `${intro}\n\n${options.map((option) => option.display).join('\n')}\n\n回复数字选择。`,
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
    const migrationOptions = normalizeFourMenu([
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
      const options = normalizeFourMenu(rawOptions, 1);
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
    const reason = isMissingArtifact
      ? '当前任务断点不完整：上次阶段结果文件缺失。请先恢复断点，再继续当前任务。'
      : isStateInvariant
      ? '当前任务的活动状态与持久副本不一致，已停止自动修复，避免覆盖任一断点。请先归档旧断点并重建任务。'
      : status === 'blocked_runtime_guard_missing'
      ? '当前 workflow 缺少运行边界，需要先修复断点账本。'
      : '当前 workflow 被运行守卫暂停，需要先处理阻塞再继续。';
    const options = normalizeFourMenu([
      numberedOption(
        1,
        isMissingArtifact ? '恢复任务断点' : isStateInvariant ? '查看任务状态修复方案' : '修复当前 workflow 运行边界',
        isMissingArtifact ? 'recover_missing_result_packet' : isStateInvariant ? 'repair_task_state' : 'repair_runtime_guard',
        isMissingArtifact ? '根据任务账本恢复上次阶段结果文件，然后回到可继续菜单。' : isStateInvariant ? '保留旧任务证据，归档后重建干净任务；不覆盖正文、大纲或报告。' : '补齐 runtime_guard / heartbeat / checkpoint 后再继续。'
      ),
      numberedOption(2, '查看可恢复任务入口', 'show_task_inbox', '只展示任务收件箱，不继续写正文或审阅。'),
      numberedOption(3, '停止并保存断点', 'pause', '保持当前文件状态，稍后再处理。'),
      numberedOption(4, '输入其他要求', 'free_text', '补充意见、纠偏、改范围或说明偏好都从这里进入。'),
    ], 1);
    return {
      render_mode: 'text_numbers',
      status,
      intro: reason,
      options,
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
  const explicitBusinessIntent = isExplicitBusinessIntent(args.userIntent);
  const projectInitialized = isInitializedWritingProject(projectRoot);
  const session = resolveSessionId(args);
  let supervisor = runSupervisor(projectRoot);
  let stateValidation = runStateValidation(projectRoot);
  let taskInbox = runTaskInbox(projectRoot, args.write);
  let taskFamilyMigration = previewTaskFamilyMigration(projectRoot);
  let migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
  let runtimeReconciliation = { exit_code: 0, result: { status: args.write ? 'skipped_preflight' : 'skipped_read_only' } };
  let autoRepair = { repaired: false };
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
      migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
    }
  }
  if (
    args.write
    && migrationTaskCount === 0
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
      migrationTaskCount = Number(taskInbox.result.migration_task_count) || 0;
    }
  }
  const outputGate = runVisibleOutputGate(args.visibleDraft ? path.resolve(args.visibleDraft) : '');
  const directIntent = explicitBusinessIntent ? buildDirectIntent(projectRoot, args.userIntent) : null;
  const runningStageControls = explicitBusinessIntent ? null : buildRunningStageControls(projectRoot);

  let status = 'pass';
  let recommendedNext = 'business_routing_allowed';
  let exitCode = 0;

  if (['blocked_workflow_session_lease', 'workflow_session_takeover_required'].includes(String(runtimeReconciliation.result.status || ''))) {
    status = 'blocked_workflow_session_lease';
    recommendedNext = 'confirm_workflow_session_takeover';
    // A live lease is an expected user-choice state, not a shell failure.
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
  if (showRunningStageControls) recommendedNext = 'show_running_stage_controls';

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
      show_task_inbox_only: status === 'task_inbox_ready' && !showRunningStageControls,
      metadata_only: true,
      migration_task_count: migrationTaskCount,
      task_family_migration_pending_count: Number(taskFamilyMigration.result.pending_task_count) || 0,
      project_initialized: projectInitialized,
      user_intent_present: String(args.userIntent || '').trim() !== '',
      explicit_business_intent: explicitBusinessIntent,
      task_inbox_deferred_for_explicit_intent: explicitBusinessIntent && status === 'pass' && ((Number(taskInbox.result.candidateCount) || 0) > 0 || (Number(taskInbox.result.recommendationCount) || 0) > 0),
    },
  };
  report.visible_response = status === 'pass' && directIntent
    ? {
      render_mode: directIntent.interaction_mode === 'resume_stage' ? 'silent_resume' : 'silent_execute',
      status: directIntent.status === 'stage_execution_resume_ready' ? directIntent.status : 'explicit_intent_ready',
      text: '',
      selection_contract: directIntent.interaction_mode === 'resume_stage' ? 'resume_running_stage' : 'execute_direct_intent_command',
      interaction_mode: directIntent.interaction_mode,
      execution_workdir: '.',
      execution_command: directIntent.execution_command,
      resume_hint: directIntent.resume_hint || '',
      stage_execution: directIntent.stage_execution || null,
      requires_user_confirm: false,
    }
    : showRunningStageControls
      ? runningStageControls
      : buildVisibleMenu(status, report.task_inbox, stateValidation.result.reason_code || '', projectRoot);
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
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    stage_id: String(execution.stage_id || ''),
    step_id: String(execution.step_id || ''),
    owner_module: String(execution.owner_module || ''),
    write_set: Array.isArray(execution.write_set) ? execution.write_set : [],
    expected_result_packet: String(execution.expected_result_packet || ''),
    execution_workdir: String(execution.execution_workdir || '.'),
    execution_command: String(execution.execution_command || ''),
    quality_command: String(execution.quality_command || ''),
    stage_completion_command: String(execution.stage_completion_command || ''),
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
  process.exit(exitCode);
}

main();
