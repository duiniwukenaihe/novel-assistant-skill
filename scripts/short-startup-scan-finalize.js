#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: args.workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'startup_scan'
      || String(execution.status || '') !== 'running'
      || String(execution.stage_id || '') !== 'startup_scan') {
    return finish({ status: 'short_startup_scan_not_running', current_stage: String(task.current_stage || '') }, 0, args.json);
  }

  const canonical = ['素材卡.md', '设定.md', '小节大纲.md', '正文.md'];
  const present = canonical.filter(file => isFile(path.join(root, file)));
  const briefs = listMatchingFiles(root, /^写作Brief_第\d+节\.md$/u);
  const drafts = listMatchingFiles(root, /^(?:草稿_第\d+节_候选|正文_第\d+节)\.md$/u);
  const projectState = firstExisting(root, [
    '追踪/story-system/short/project-state.json',
    '追踪/private-short-extension/project-state.json',
  ]);
  const infoPool = '追踪/private-short-extension/cards/info-source-cards.jsonl';
  const projectKind = present.length || briefs.length || drafts.length || projectState
    ? 'existing_short_project'
    : 'new_short_project';
  const artifactRel = `${task.task_dir}/artifacts/startup-scan.json`;
  const artifactFile = safeProjectFile(root, artifactRel);
  atomicWriteJson(artifactFile, {
    schemaVersion: '1.0.0',
    status: 'short_startup_scan_completed',
    project_kind: projectKind,
    canonical_assets: present,
    brief_count: briefs.length,
    draft_count: drafts.length,
    project_state: projectState,
    info_pool_present: isFile(path.join(root, infoPool)),
    scanned_at: new Date().toISOString(),
  });

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/startup_scan.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'startup_scan',
    step_id: 'startup_scan',
    owner_module: String(execution.owner_module || 'private-short-extension'),
    step_status: 'completed',
    outputs: [artifactRel],
    changed_files: [],
    created_files: [artifactRel],
    evidence: [{ project_kind: projectKind, canonical_assets: present, brief_count: briefs.length, draft_count: drafts.length }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'startup_scan', completed_range: '项目状态扫描完成', remaining_range: '显示短篇启动菜单', resume_from: '' },
    handoff_summary: projectKind === 'new_short_project' ? '确认这是新短篇项目。' : '已识别现有短篇资产。',
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'), 'apply-result',
    '--project-root', root,
    '--workflow-id', String(task.workflow_id || ''),
    '--result', packetFile,
    '--compact', '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'short_startup_ready' : 'short_startup_scan_apply_blocked',
    workflow_id: String(task.workflow_id || ''),
    project_kind: projectKind,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function listMatchingFiles(root, pattern) {
  return fs.readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isFile() && pattern.test(entry.name))
    .map(entry => entry.name)
    .sort();
}
function firstExisting(root, candidates) { return candidates.find(file => isFile(path.join(root, file))) || ''; }
function isFile(file) { return fs.existsSync(file) && fs.statSync(file).isFile(); }
function safeProjectFile(root, relative) {
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe project path: ${relative}`);
  return file;
}
function parseArgs(argv) {
  const out = { projectRoot: '.', workflowId: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '.';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--json') out.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!out.workflowId) throw new Error('--workflow-id is required');
  return out;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : String(value.status || '')}\n`); return code; }

process.exitCode = main();
