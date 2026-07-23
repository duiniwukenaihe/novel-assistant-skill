#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { atomicWriteJson } = require('./lib/workflow-state-store');

const STAGES = new Set(['hook_value_gate', 'hook_retention_gate']);
const CHECKS = ['title_promise', 'opening_pressure', 'plot_spikes', 'golden_reading_map', 'section_breakpoints', 'dropoff_risk', 'protagonist_agency', 'causal_chain'];

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: args.workflowId }, 0, args.json);
  const task = authority.task;
  const stageId = String(task.current_stage || '');
  const execution = task.stage_execution || {};
  if (!STAGES.has(stageId) || String(execution.status || '') !== 'running') {
    return finish({ status: 'stage_action_not_applicable', expected: [...STAGES], actual: stageId, instruction: '读取当前阶段提供的 execution_command，不要重试旧命令。' }, 0, args.json);
  }
  const artifactRoot = `${task.task_dir}/artifacts/${stageId}`;
  const evidenceRel = `${artifactRoot}/evidence-pack.json`;
  const cardRel = `${artifactRoot}/review-card.json`;
  const evidence = buildEvidence(root, task, stageId);
  atomicWriteJson(path.join(root, evidenceRel), evidence);
  const cardFile = path.join(root, cardRel);
  if (!fs.existsSync(cardFile)) {
    return finish(reviewRequired(task, stageId, evidence, evidenceRel, cardRel), 0, args.json);
  }
  const card = readJson(cardFile);
  if (card && String(card.evidence_digest || '') !== String(evidence.digest || '')) {
    const staleRel = `${artifactRoot}/review-card.stale-${safeSegment(card.evidence_digest || 'unknown').slice(0, 16)}.json`;
    atomicWriteJson(path.join(root, staleRel), card);
    fs.unlinkSync(cardFile);
    return finish(reviewRequired(task, stageId, evidence, evidenceRel, cardRel, {
      reason: 'planning_evidence_changed',
      stale_review_card: staleRel,
    }), 0, args.json);
  }
  const findings = validateCard(card, evidence);
  if (findings.length) return finish({ status: 'short_hook_value_review_invalid', review_card: cardRel, findings, instruction: '只修审阅卡缺失字段后重跑同一命令，不要重读项目。' }, 0, args.json);
  const decision = String(card.decision || '');
  const nextStage = decision === 'revise' ? String(card.repair_layer || 'section_outline') : '';
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/${stageId}.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''), workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId, step_id: stageId, owner_module: String(execution.owner_module || task.workflow_owner || 'story-short-write'),
    step_status: 'completed', outputs: [evidenceRel, cardRel], changed_files: [], created_files: [evidenceRel, cardRel],
    evidence: [{ type: 'short_hook_value_review', evidence_pack: evidenceRel, review_card: cardRel, decision }],
    verification_result: 'pass', blocking_findings: [], output_health_result: 'pass',
    checkpoint_state: { current_stage: stageId, completed_range: '看点价值已审阅', remaining_range: decision === 'pass' ? '生成首个写作提要' : '回写规划层', resume_from: nextStage },
    next_stage_id: nextStage,
    handoff_summary: String(card.summary || ''), memory_updates: [], result_packet_path: packetRel,
  });
  if (!args.apply) return finish({ status: 'short_hook_value_ready', decision, result_packet: packetRel }, 0, args.json);
  const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', String(task.workflow_id || ''), '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(run);
  return finish({ status: outcome.applied ? 'short_hook_value_completed' : 'short_hook_value_apply_blocked', decision, workflow_status: outcome.workflowStatus, ...outcome.presentation, ...(outcome.applied ? {} : { recovery: outcome.result }) }, outcome.exitCode, args.json);
}

function buildEvidence(root, task, stageId) {
  const sources = ['素材卡.md', '设定.md', '小节大纲.md'].filter(rel => fs.existsSync(path.join(root, rel))).map(rel => ({ path: rel, content: fs.readFileSync(path.join(root, rel), 'utf8').slice(0, rel === '小节大纲.md' ? 18000 : 8000) }));
  const payload = { schemaVersion: '1.0.0', workflow_id: String(task.workflow_id || ''), stage_id: stageId, checks: CHECKS, sources };
  payload.digest = crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  return payload;
}
function reviewRequired(task, stageId, evidence, evidenceRel, cardRel, extra = {}) {
  return {
    status: 'short_hook_value_review_required',
    workflow_id: String(task.workflow_id || ''),
    stage_id: stageId,
    evidence_pack: evidenceRel,
    review_card: cardRel,
    instruction: `只读取 ${evidenceRel}，按 review_card_schema 写一张看点价值审阅卡到 ${cardRel}，再重跑同一 execution_command。不要修改正文或规划资产。`,
    review_card_schema: {
      schemaVersion: '1.0.0', workflow_id: String(task.workflow_id || ''), evidence_digest: evidence.digest,
      decision: 'pass|revise', repair_layer: 'section_outline|short_setting|none', summary: '<结论>',
      checks: CHECKS.map(id => ({ id, status: 'pass|revise', evidence: '<大纲/设定中的可核验依据>', repair_direction: '<需要修改时填写>' })),
    },
    ...extra,
  };
}
function validateCard(card, evidence) {
  const findings = [];
  if (!card || typeof card !== 'object') return [{ field: 'review_card', message: '审阅卡不是有效 JSON。' }];
  if (String(card.workflow_id || '') !== String(evidence.workflow_id || '')) findings.push({ field: 'workflow_id', message: '审阅卡不属于当前任务。' });
  if (String(card.evidence_digest || '') !== String(evidence.digest || '')) findings.push({ field: 'evidence_digest', message: '规划证据已变化，请重新审阅。' });
  if (!['pass', 'revise'].includes(String(card.decision || ''))) findings.push({ field: 'decision', message: 'decision 必须为 pass 或 revise。' });
  const checks = new Map((Array.isArray(card.checks) ? card.checks : []).map(item => [String((item || {}).id || ''), item]));
  for (const id of CHECKS) { const item = checks.get(id); if (!item || !['pass', 'revise'].includes(String(item.status || '')) || !String(item.evidence || '').trim()) findings.push({ field: `checks.${id}`, message: '必须给出判断和可核验依据。' }); }
  if (String(card.decision || '') === 'revise' && !['section_outline', 'short_setting'].includes(String(card.repair_layer || ''))) findings.push({ field: 'repair_layer', message: '需要回炉时必须明确回设定或小节大纲。' });
  return findings;
}
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function safeSegment(value) { return String(value || '').replace(/[^A-Za-z0-9._-]/g, '_') || 'unknown'; }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', apply: false, json: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--apply') args.apply = true; else if (arg === '--json') args.json = true; else usage(`unknown argument: ${arg}`); } if (!args.workflowId) usage('missing --workflow-id'); return args; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-hook-value-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }

process.exitCode = main();
