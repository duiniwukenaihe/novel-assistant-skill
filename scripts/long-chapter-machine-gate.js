#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply, recoverableStageResult } = require('./lib/workflow-apply-result');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferLongChapter, resolveChapterDraft } = require('./lib/long-stage-context-packet');
const { evaluateLongChapterLength } = require('./lib/long-chapter-length-contract');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { invokeApplyResult, invokeResolveAction } = require('./lib/workflow-state-machine-invoke');
const { parseJson } = require('./lib/cli-utils');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  if (String(task.workflow_type || '') !== 'long_write' || String(task.current_stage || '') !== 'prose_acceptance') {
    return finish({ status: 'blocked_wrong_stage', expected: 'long_write.prose_acceptance', actual: `${task.workflow_type || ''}.${task.current_stage || ''}` }, 2, args.json);
  }
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'prose_acceptance') return finish({ status: 'blocked_stage_execution_required' }, 2, args.json);
  const chapterTarget = execution.chapter_target || task.active_chapter_target || {};
  const chapter = inferLongChapter(root, task, 'prose_acceptance');
  const volume = String(chapterTarget.volume || '') || volumeFromTask(task);
  const draft = args.draft ? safeProjectFile(root, args.draft) : resolveChapterDraft(root, task, chapterTarget);
  if (!chapter || !draft || !fs.existsSync(draft)) return finish(recoverableStageResult(task, 'blocked_long_draft_missing', '恢复当前章候选稿后重新运行章节机器检查；不要创建空正文或跳到下一章。', { chapter, draft: args.draft || '' }), 0, args.json);
  const contract = safeProjectFile(root, chapterTarget.contract_path || '');
  const checks = runChecks(root, draft, contract);
  const blocking = checks.filter((item) => item.blocking);
  const evidenceRel = `${task.task_dir}/artifacts/chapter-${String(chapter).padStart(3, '0')}-machine-gate.json`;
  atomicWriteJson(safeProjectFile(root, evidenceRel), { schemaVersion: '1.0.0', workflow_id: workflowId, chapter, volume, draft: relative(root, draft), checks, blocking_count: blocking.length, status: blocking.length ? 'blocking' : 'pass', created_at: new Date().toISOString() });
  const repairCommand = `node scripts/long-chapter-machine-gate.js --project-root . --workflow-id ${JSON.stringify(workflowId)} --apply --json`;
  const base = { workflow_id: workflowId, chapter, draft: relative(root, draft), evidence: evidenceRel, blocking_findings: blocking.map((item) => ({ code: item.id, message: item.message })), next_command: blocking.length ? repairCommand : `node scripts/long-chapter-quality-gate.js --project-root . --workflow-id ${JSON.stringify(workflowId)} --decision <pass|revise> --apply --json` };
  if (blocking.length && args.apply) return finish(returnToProse(root, task, execution, base), 0, args.json);
  if (blocking.length) return finish(recoverableStageResult(task, 'blocking', '运行 next_command 退回当前章正文修订；只修机器检查发现的问题，不要重写大纲或继续下一章。', base), 0, args.json);
  return finish({ status: 'pass', ...base }, 0, args.json);
}

function returnToProse(root, task, execution, base) {
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/prose_acceptance.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const findings = Array.isArray(base.blocking_findings) ? base.blocking_findings : [];
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: 'long_write',
    stage_id: 'prose_acceptance',
    step_id: 'prose_acceptance',
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    work_unit_id: String(execution.work_unit_id || ''),
    owner_module: String(execution.owner_module || 'story-review'),
    lifecycle_node: String(execution.lifecycle_node || 'prose_acceptance'),
    asset_target: { ...(execution.asset_target || {}) },
    review_requirement: { ...(execution.review_requirement || {}) },
    chapter_target: JSON.parse(JSON.stringify(execution.chapter_target || task.active_chapter_target || {})),
    step_status: 'blocked',
    outputs: [String(base.draft || ''), String(base.evidence || '')],
    changed_files: [],
    evidence: [{ chapter: base.chapter, draft: String(base.draft || ''), machine_gate: 'blocking' }],
    verification_result: 'rejected',
    machine_gate_result: 'blocking',
    story_value_result: 'not_run',
    blocking_findings: findings,
    checkpoint_state: { current_stage: 'prose_acceptance', completed_range: '', remaining_range: `第${base.chapter}章机器问题修订`, resume_from: 'prose' },
    output_health_result: 'pass',
    next_stage_id: 'prose',
    next_recommendation: '只修当前章机器检查阻断项，不重写大纲或下一章。',
    handoff_summary: `第${base.chapter}章机器检查未通过，已退回当前章正文修订。`,
    memory_read_receipt: ((execution.memory_context || {}).memory_read_receipt) || null,
    asset_revision: { status: 'revision_required', asset_id: String((execution.asset_target || {}).id || 'current-chapter') },
    review_decision: 'rejected',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'return', target: 'prose' },
    result_write_set: [],
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = invokeApplyResult({ projectRoot: root, workflowId: String(task.workflow_id || ''), resultFile: packetFile });
  let outcome = classifyWorkflowApply(applied);
  let repairExecution = null;
  if (outcome.applied) {
    const options = Array.isArray(outcome.presentation.next_candidates) ? outcome.presentation.next_candidates : [];
    const repair = options.find((item) => String(item.action_id || '') === 'continue_next_stage'
      && String(item.target_stage || '') === 'prose');
    if (repair) {
      const started = invokeResolveAction({ projectRoot: root, input: String(repair.number), bindCurrent: true });
      outcome = classifyWorkflowApply(started);
      if (outcome.applied) repairExecution = attachRepairFeedback(root, task.workflow_id, findings);
    }
  }
  return {
    status: outcome.applied ? 'repair_started' : 'repair_blocked',
    workflow_status: outcome.workflowStatus,
    ...base,
    ...outcome.presentation,
    ...(repairExecution ? { stage_execution: repairExecution } : {}),
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  };
}

function attachRepairFeedback(root, workflowId, findings) {
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return null;
  const task = authority.task;
  if (String(task.current_stage || '') !== 'prose'
      || String(((task || {}).stage_execution || {}).stage_id || '') !== 'prose') return null;
  const feedback = (Array.isArray(findings) ? findings : [])
    .map((finding) => `[${String((finding || {}).code || 'machine_gate')}] ${String((finding || {}).message || '').trim()}`)
    .filter((item) => item.trim())
    .slice(0, 5);
  if (feedback.length === 0) return task.stage_execution || null;
  const next = mutateTaskAuthority(root, workflowId, Number(task.state_version || 0), (draft) => {
    draft.stage_execution = {
      ...(draft.stage_execution || {}),
      resume_hint: `机器门只要求修复当前候选：${feedback.join('；')}。保留其余正文，不改大纲，不重写全章；修完重新提交 prose 回执。`,
      repair_feedback: {
        source_stage: 'prose_acceptance',
        findings: JSON.parse(JSON.stringify(findings)),
      },
    };
    return draft;
  });
  return next.stage_execution || null;
}

function runChecks(root, draft, contract) {
  const lengthResult = evaluateLongChapterLength(
    contract && fs.existsSync(contract) && fs.statSync(contract).isFile() ? fs.readFileSync(contract, 'utf8') : '',
    fs.readFileSync(draft, 'utf8'),
  );
  const commands = [
    ['check-ai-patterns', 'check-ai-patterns.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['anti-ai-diagnose', 'anti-ai-diagnose.js', ['--json', '--work-type=longform', '--prose-profile=fiction', draft]],
    ['output-pollution-check', 'output-pollution-check.js', ['--check', '--json', draft]],
    ['check-degeneration', 'check-degeneration.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['story-prose-gate', 'story-prose-gate.js', [draft, '--json']],
  ];
  return [{
    id: 'long-chapter-length',
    status: lengthResult.status,
    blocking: lengthResult.status !== 'pass',
    exit_code: lengthResult.status === 'pass' ? 0 : 1,
    message: lengthResult.message,
    evidence: lengthResult,
  }, ...commands.map(([id, script, cliArgs]) => {
    const run = spawnSync(process.execPath, [path.join(__dirname, script), ...cliArgs], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
    const parsed = parseJson(run.stdout);
    const blocking = run.status !== 0 || hasBlocking(parsed);
    return { id, status: blocking ? 'blocking' : 'pass', blocking, exit_code: Number.isInteger(run.status) ? run.status : 1, message: blocking ? firstMessage(parsed, run.stderr) : '' };
  })];
}
function hasBlocking(value) { if (!value || typeof value !== 'object') return false; if (Array.isArray(value)) return value.some(hasBlocking); return Object.entries(value).some(([key, child]) => (/blocking|blocked/i.test(key) && (child === true || Number(child) > 0)) || (/status|result|verdict/i.test(key) && typeof child === 'string' && /(block|fail|reject|error)/i.test(child)) || (/severity/i.test(key) && String(child).toLowerCase() === 'blocking') || hasBlocking(child)); }
function firstMessage(parsed, stderr) {
  const queue = [parsed];
  const fallback = [];
  while (queue.length) {
    const item = queue.shift();
    if (!item || typeof item !== 'object') continue;
    const message = typeof item.message === 'string' ? item.message.trim() : '';
    const itemBlocking = item.blocking === true
      || String(item.severity || '').toLowerCase() === 'blocking'
      || /(block|fail|reject|error)/i.test(String(item.status || item.result || item.verdict || ''));
    if (message && itemBlocking) return message.slice(0, 300);
    if (message) fallback.push(message);
    queue.push(...(Array.isArray(item) ? item : Object.values(item)));
  }
  if (fallback.length > 0) return fallback[0].slice(0, 300);
  return String(stderr || '检查器未通过').trim().slice(0, 300);
}
function volumeFromTask(task) { const match = `${task.scope || ''} ${task.user_goal || ''}`.match(/第\s*([0-9一二三四五六七八九十百]+)\s*卷/); return match ? `第${match[1]}卷` : ''; }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', draft: '', apply: false, json: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--draft') args.draft = argv[++i] || ''; else if (arg === '--apply') args.apply = true; else if (arg === '--json') args.json = true; else usage(`unknown argument: ${arg}`); } return args; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }
function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }


function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node long-chapter-machine-gate.js --project-root <book> --workflow-id <id> [--draft file] [--apply] [--json]\n`); process.exit(2); }

process.exitCode = main();
