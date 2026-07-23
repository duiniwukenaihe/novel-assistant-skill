#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { atomicWriteJson } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: args.workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'short_structure_impact_audit'
      || String(execution.status || '') !== 'running') {
    return finish({ status: 'stage_action_not_applicable', expected: 'short_structure_impact_audit', actual: task.current_stage || '', instruction: '读取当前阶段提供的 execution_command，不要重试旧命令。' }, 0, args.json);
  }

  const report = buildImpactReport(root, task);
  const artifactRel = `${task.task_dir}/artifacts/short-structure-impact-audit.json`;
  atomicWriteJson(path.join(root, artifactRel), report);
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/short_structure_impact_audit.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_structure_impact_packet_path' }, 0, args.json);
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'short_structure_impact_audit',
    step_id: 'short_structure_impact_audit',
    owner_module: String(execution.owner_module || task.workflow_owner || 'story-short-write'),
    step_status: 'completed',
    outputs: [artifactRel],
    changed_files: [],
    created_files: [artifactRel],
    evidence: [{ type: 'short_structure_impact', artifact: artifactRel, summary: report.summary }],
    verification_result: report.unassigned_blocking.length ? 'blocked' : 'pass',
    blocking_findings: report.unassigned_blocking,
    output_health_result: 'pass',
    checkpoint_state: {
      current_stage: 'short_structure_impact_audit',
      completed_range: '结构变更影响已分类并分配恢复责任',
      remaining_range: report.unassigned_blocking.length ? '补齐未分配的失效制品' : '进入看点价值门',
      resume_from: report.unassigned_blocking.length ? 'short_structure_impact_audit' : '',
    },
    handoff_summary: report.summary,
    affected_sections: report.affected_sections,
    downstream_impact: {
      invalidate_briefs: report.affected_sections,
      recheck_prose: report.affected_sections,
    },
    memory_updates: [],
    result_packet_path: packetRel,
  });
  if (!args.apply || report.unassigned_blocking.length) {
    return finish({ status: report.unassigned_blocking.length ? 'short_structure_impact_blocked' : 'short_structure_impact_ready', report: artifactRel, result_packet: packetRel, findings: report.unassigned_blocking }, 0, args.json);
  }
  const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', String(task.workflow_id || ''), '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(run);
  return finish({
    status: outcome.applied ? 'short_structure_impact_completed' : 'short_structure_impact_apply_blocked',
    workflow_id: String(task.workflow_id || ''),
    report: artifactRel,
    workflow_status: outcome.workflowStatus,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function buildImpactReport(root, task) {
  const changed = new Set((((task.accepted_plan || {}).projection_plan || {}).planning_assets || []).map(normalizeRel));
  const affected = new Set([
    ...((((task.accepted_plan || {}).affected_sections) || []).map(Number)),
    ...(((((task.feedback_revision_queue || task.short_feedback_revision_queue || {}).affected_sections) || [])).map(Number)),
  ].filter(Number.isInteger));
  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const acceptedTitles = new Map((Array.isArray(projectState.accepted_sections) ? projectState.accepted_sections : [])
    .map(entry => [Number((entry || {}).section_index || 0), normalizeTitle((entry || {}).title)]));
  const titleChangedSections = (Array.isArray(titleLock.sections) ? titleLock.sections : [])
    .filter(entry => {
      const index = Number((entry || {}).section_index || 0);
      return Number.isInteger(index) && index > 0 && acceptedTitles.has(index)
        && normalizeTitle((entry || {}).title) !== acceptedTitles.get(index);
    })
    .map(entry => Number(entry.section_index));
  titleChangedSections.forEach(index => affected.add(index));
  const planned = Number(titleLock.planned_sections || ((titleLock.sections || []).length) || 0);
  const items = [];
  const planningOwners = { '素材卡.md': 'material_card', '设定.md': 'short_setting', '小节大纲.md': 'section_outline' };
  for (const rel of ['素材卡.md', '设定.md', '小节大纲.md']) {
    const exists = fs.existsSync(path.join(root, rel));
    const disposition = exists ? (changed.has(rel) ? 'recheck' : 'keep') : 'recompute';
    items.push(item(rel, disposition, changed.has(rel) ? 'accepted_plan' : 'current_canonical', disposition === 'recompute' ? planningOwners[rel] : ''));
  }
  items.push(item('追踪/private-short-extension/section-title-lock.json', titleLock.status === 'confirmed' ? 'keep' : 'recompute', 'section_plan_lock', titleLock.status === 'confirmed' ? '' : 'section_plan_lock'));
  for (const index of affected) {
    const suffix = String(index).padStart(3, '0');
    items.push(item(`写作Brief_第${suffix}节.md`, 'invalidated', 'planning_changed', index === 1 ? 'first_section_brief' : 'next_section_brief'));
    items.push(item(`追踪/private-short-extension/section-${suffix}-anchor.json`, 'recheck', 'accepted_prose_preserved', 'quality_gate'));
    items.push(item(`正文/第${suffix}节.md`, 'recheck', 'accepted_prose_preserved', 'quality_gate'));
  }
  if (affected.size || changed.has('小节大纲.md')) items.push(item('正文.md', 'recompute', 'downstream_structure_changed', 'full_story_assembly'));
  const unassigned = items.filter(entry => ['invalidated', 'recompute'].includes(entry.disposition) && !entry.owner_stage)
    .map(entry => ({ code: 'structure_impact_owner_missing', asset: entry.asset, disposition: entry.disposition }));
  return {
    schemaVersion: '1.0.0',
    workflow_id: String(task.workflow_id || ''),
    planned_sections: planned,
    affected_sections: [...affected].sort((a, b) => a - b),
    title_changed_sections: titleChangedSections.sort((a, b) => a - b),
    changed_planning_assets: [...changed],
    items,
    unassigned_blocking: unassigned,
    summary: affected.size
      ? `结构影响已收束：${affected.size} 个小节进入复检，旧正文默认保留，受影响 Brief 重建，合稿随后重算。`
      : '结构未改变；现有规划、标题锁和已采用正文可以继续复用。',
  };
}

function item(asset, disposition, reason, ownerStage) { return { asset, disposition, reason, owner_stage: ownerStage || '' }; }
function normalizeRel(value) { return String(value || '').replace(/\\/g, '/').replace(/^\.\//, ''); }
function normalizeTitle(value) { return String(value || '').trim().replace(/[“”]/gu, '"').replace(/\s+/gu, ' '); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', apply: false, json: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--apply') args.apply = true; else if (arg === '--json') args.json = true; else usage(`unknown argument: ${arg}`); } if (!args.workflowId) usage('missing --workflow-id'); return args; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-structure-impact-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }

process.exitCode = main();
