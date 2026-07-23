#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolvePlannedSectionCount } = require('./lib/short-workflow-state');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { appendIntegrationEvent } = require('./lib/integration-outbox');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'final_check' || String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'final_check') {
    return finish({ status: 'stage_action_not_applicable', expected: 'final_check', actual: task.current_stage || '', instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  const proseFile = path.join(root, '正文.md');
  if (!fs.existsSync(proseFile)) return finish({ status: 'short_final_prose_missing', instruction: '返回全文组装阶段恢复 正文.md。' }, 0, args.json);
  const text = fs.readFileSync(proseFile, 'utf8');
  const plan = resolvePlannedSectionCount({ projectState: readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {}, titleLock: readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {}, outlineText: readText(path.join(root, '小节大纲.md')) });
  const headings = [...text.matchAll(/^##\s+第\s*0*(\d+)\s*节\b/gmu)].map((match) => Number(match[1]));
  const expected = plan.status === 'locked' ? Array.from({ length: plan.count }, (_, index) => index + 1) : [];
  const deslop = readJson(path.join(root, `${task.task_dir}/result-packets/short_deslop.result.json`))
    || readJson(path.join(root, `${task.task_dir}/result-packets/deslop.result.json`))
    || {};
  const editorial = readJson(path.join(root, `${task.task_dir}/result-packets/full_story_review.result.json`)) || {};
  const expectedHash = String((((deslop.short_deslop_commit || {}).canonical_sha256) || (((deslop.evidence || [])[0] || {}).canonical_sha256) || ''));
  const deslopSourceHash = String(((deslop.short_deslop_commit || {}).source_canonical_sha256) || '');
  const editorialProof = editorial.short_full_story_review || {};
  const preservation = deslop.preservation_result || {};
  const actualHash = hashText(text);
  const findings = [];
  if (plan.status !== 'locked') findings.push({ code: 'planned_sections_not_locked', message: '全篇小节数尚未锁定。' });
  if (headings.length !== expected.length || headings.some((value, index) => value !== expected[index])) findings.push({ code: 'section_sequence_mismatch', expected, actual: headings });
  if (!expectedHash || expectedHash !== actualHash) findings.push({ code: 'deslop_receipt_hash_mismatch', expected: expectedHash, actual: actualHash });
  if (String(editorialProof.decision || '') !== 'pass') findings.push({ code: 'full_story_editorial_review_not_passed', decision: String(editorialProof.decision || '') });
  if (!deslopSourceHash || deslopSourceHash !== String(editorialProof.story_sha256 || '')) findings.push({ code: 'full_story_editorial_review_stale', reviewed: String(editorialProof.story_sha256 || ''), deslop_source: deslopSourceHash });
  if (!['pass', 'explicit_exception'].includes(String(preservation.status || ''))) findings.push({ code: 'short_deslop_preservation_missing', status: String(preservation.status || '') });
  if (findings.length) return finish({ status: 'short_final_check_blocked', visible_status: { code: 'publication_conditions_incomplete', label: '短篇尚未具备发布条件' }, findings, instruction: '按 findings 修复正式稿或回执后重跑本命令；不要重新写全篇。' }, 0, args.json);
  if (!args.apply) return finish({ status: 'short_final_check_ready', visible_status: { code: 'publication_ready', label: '短篇已具备发布条件' }, planned_sections: plan.count, canonical_sha256: actualHash }, 0, args.json);
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/final_check.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId, workflow_type: String(task.workflow_type || 'short_write'), stage_id: 'final_check', step_id: 'final_check',
    owner_module: String(execution.owner_module || task.workflow_owner || ''), step_status: 'completed', scope: '全篇', outputs: ['正文.md'], changed_files: [], created_files: [],
    evidence: [{ planned_sections: plan.count, assembled_sections: headings.length, canonical_sha256: actualHash, editorial_review_sha256: String(editorialProof.story_sha256 || ''), deslop_preservation_status: String(preservation.status || ''), before_deslop_cjk_chars: Number(preservation.before_cjk_chars || 0), after_deslop_cjk_chars: Number(preservation.after_cjk_chars || 0) }], verification_result: 'pass', blocking_findings: [], output_health_result: 'pass',
    checkpoint_state: { current_stage: 'final_check', completed_range: '短篇全流程完成', remaining_range: '', resume_from: '' }, next_stage_id: '', next_recommendation: '短篇已完成，可导出或开启新的修改任务。', handoff_summary: `最终检查通过：${plan.count} 节完整，正式稿与去 AI 回执一致。`, memory_updates: [], result_packet_path: packetRel,
  });
  const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(run);
  let integrationEvent = null;
  if (outcome.applied) {
    const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
    try {
      integrationEvent = appendIntegrationEvent(root, {
        event_type: 'story_completed',
        workflow_id: workflowId,
        project_id: String(projectState.project_id || ''),
        project_title: String(projectState.project_title || projectState.title || ''),
        artifact_path: '正文.md',
        artifact_digest: `sha256:${actualHash}`,
        summary: `短篇已完成最终检查，共 ${plan.count} 节。`,
        tags: ['short_write', 'completed'],
      });
    } catch (error) {
      integrationEvent = { status: 'deferred', message: String(error.message || error) };
    }
  }
  return finish({
    status: outcome.applied ? 'completed' : 'apply_blocked',
    workflow_id: workflowId,
    result_packet: packetRel,
    workflow_status: outcome.workflowStatus,
    integration_event: integrationEvent,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function hashText(value) { return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex'); }
function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') out.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-story-final-check.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-story-final-check.js --project-root <book> --workflow-id <id> [--apply] [--json]\n'); return 0; }

process.exitCode = main();
