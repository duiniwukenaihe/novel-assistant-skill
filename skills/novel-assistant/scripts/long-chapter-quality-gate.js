#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply, recoverableStageResult } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferLongChapter, resolveChapterDraft } = require('./lib/long-stage-context-packet');
const { atomicWriteJson } = require('./lib/workflow-state-store');

const CHECKS = ['brief_alignment', 'causal_chain', 'character_consistency', 'promise_and_hook', 'protagonist_agency', 'continuity', 'story_attraction', 'drift_control'];

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  if (String(task.workflow_type || '') !== 'long_write' || String(task.current_stage || '') !== 'prose_acceptance') return finish({ status: 'blocked_wrong_stage', expected: 'long_write.prose_acceptance', actual: `${task.workflow_type || ''}.${task.current_stage || ''}` }, 2, args.json);
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'prose_acceptance') return finish({ status: 'blocked_stage_execution_required' }, 2, args.json);
  if (!['pass', 'revise'].includes(args.decision)) {
    const base = `node scripts/long-chapter-quality-gate.js --project-root . --workflow-id ${JSON.stringify(workflowId)}`;
    return finish(recoverableStageResult(task, 'blocked_decision_required', '完成当前章八项故事质量判断后，从两条确定性命令中选择一条执行。', {
      allowed: ['pass', 'revise'],
      decision_commands: {
        pass: `${base} --decision pass --apply --json`,
        revise: `${base} --decision revise --apply --json`,
      },
    }), 0, args.json);
  }
  const chapter = inferLongChapter(root, task, 'prose_acceptance');
  const volume = volumeFromTask(task);
  const draft = args.draft ? safeProjectFile(root, args.draft) : resolveChapterDraft(root, task, chapter, volume);
  const machineRel = `${task.task_dir}/artifacts/chapter-${String(chapter).padStart(3, '0')}-machine-gate.json`;
  const machine = readJson(safeProjectFile(root, machineRel));
  if (!machine || machine.status !== 'pass' || Number(machine.blocking_count || 0) > 0) return finish(recoverableStageResult(task, 'blocked_machine_gate_required', '先完成当前章机器检查并修完阻断项，再回到故事质量检查。', { machine_evidence: machineRel }), 0, args.json);
  if (!draft || !fs.existsSync(draft)) return finish(recoverableStageResult(task, 'blocked_long_draft_missing', '恢复当前章候选稿后重新运行质量检查；不要创建空正文或跳到下一章。', { chapter }), 0, args.json);
  const failed = new Set(args.failed.filter((item) => CHECKS.includes(item)));
  if (args.decision === 'revise' && failed.size === 0) failed.add('story_attraction');
  if (args.decision === 'pass' && failed.size) return finish(recoverableStageResult(task, 'blocked_quality_decision_conflict', '质量证据仍有需修订项；修订当前章或把结论改为 revise 后重跑。', { failed: [...failed] }), 0, args.json);
  const passed = args.decision === 'pass';
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/prose_acceptance.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const stageContract = { owner_module: String(execution.owner_module || 'story-review'), lifecycle_node: String(execution.lifecycle_node || 'prose_acceptance'), asset_target: { ...(execution.asset_target || {}) }, review_requirement: { ...(execution.review_requirement || {}) } };
  atomicWriteJson(packetFile, {
    workflow_id: workflowId, workflow_type: 'long_write', stage_id: 'prose_acceptance', step_id: 'prose_acceptance', ...stageContract,
    step_status: passed ? 'completed' : 'blocked', outputs: [relative(root, draft), machineRel], changed_files: [machineRel],
    evidence: [{ chapter, volume, draft: relative(root, draft), machine_gate: 'pass', checks: CHECKS.map((id) => ({ id, status: failed.has(id) ? 'revise' : 'pass' })), summary: args.summary || '' }],
    verification_result: passed ? 'accepted' : 'rejected', machine_gate_result: 'pass', story_value_result: passed ? 'pass' : 'revise',
    blocking_findings: [...failed].map((id) => ({ code: id, message: `${id} 需要修订` })),
    checkpoint_state: { current_stage: 'prose_acceptance', completed_range: passed ? `第${chapter}章验收` : '', remaining_range: passed ? '章节事务提交' : `第${chapter}章修订`, resume_from: passed ? 'chapter_commit' : 'prose' },
    output_health_result: 'pass', next_stage_id: passed ? 'chapter_commit' : 'prose', next_recommendation: passed ? '进入章节事务提交。' : '只修当前章，不重写大纲或下一章。',
    handoff_summary: passed ? `第${chapter}章机器门与故事质量门通过。` : `第${chapter}章需修订：${[...failed].join(', ')}。`,
    memory_read_receipt: ((execution.memory_context || {}).memory_read_receipt) || null,
    asset_revision: { status: passed ? 'verified' : 'revision_required', asset_id: String((execution.asset_target || {}).id || 'current-chapter') },
    review_decision: passed ? 'accepted' : 'rejected', downstream_effects: [], lifecycle_transition_request: { action: passed ? 'advance' : 'return', target: passed ? 'prose_acceptance' : 'prose' },
    result_write_set: [machineRel], memory_updates: [], result_packet_path: packetRel,
  });
  if (!args.apply) return finish({ status: 'packet_ready', workflow_id: workflowId, chapter, decision: args.decision, result_packet: packetRel }, 0, args.json);
  const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  const result = outcome.result;
  return finish({ status: outcome.applied ? 'applied' : 'apply_blocked', workflow_status: outcome.workflowStatus, workflow_id: workflowId, chapter, decision: args.decision, result_packet: packetRel, next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''), ...outcome.presentation, ...(outcome.applied ? {} : { recovery: result }) }, outcome.exitCode, args.json);
}

function volumeFromTask(task) { const match = `${task.scope || ''} ${task.user_goal || ''}`.match(/第\s*([0-9一二三四五六七八九十百]+)\s*卷/); return match ? `第${match[1]}卷` : ''; }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', draft: '', decision: '', failed: [], summary: '', apply: false, json: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--draft') args.draft = argv[++i] || ''; else if (arg === '--decision') args.decision = String(argv[++i] || '').toLowerCase(); else if (arg === '--failed') args.failed = String(argv[++i] || '').split(',').map((item) => item.trim()).filter(Boolean); else if (arg === '--summary') args.summary = String(argv[++i] || '').slice(0, 300); else if (arg === '--apply') args.apply = true; else if (arg === '--json') args.json = true; else usage(`unknown argument: ${arg}`); } return args; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }
function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node long-chapter-quality-gate.js --project-root <book> --workflow-id <id> --decision <pass|revise> [--failed a,b] [--draft file] [--apply] [--json]\n`); process.exit(2); }

process.exitCode = main();
