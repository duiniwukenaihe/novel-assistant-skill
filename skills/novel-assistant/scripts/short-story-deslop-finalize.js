#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, inspectChapter, prepareTransaction } = require('./lib/chapter-commit-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { commitAcceptedSection } = require('./lib/short-section-commit-store');
const { preservationCheck } = require('./lib/short-deslop-preservation');
const { resolvePlannedSectionCount } = require('./lib/short-workflow-state');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');

const VOLUME = '短篇发布稿';

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  const stageId = String(task.current_stage || '');
  if (!['short_deslop', 'deslop'].includes(stageId) || String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_action_not_applicable', expected: 'short_deslop|deslop', actual: task.current_stage || '', instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  const stagedRel = String(execution.deslop_target || '');
  const stagedFile = safeProjectFile(root, stagedRel);
  if (!stagedFile || !fs.existsSync(stagedFile)) {
    return finish({ status: 'short_deslop_staged_draft_missing', staged_target: stagedRel, instruction: '重新启动当前阶段生成暂存稿；不要直接修改 正文.md。' }, 0, args.json);
  }

  const text = fs.readFileSync(stagedFile, 'utf8');
  const sourceFile = path.join(root, '正文.md');
  if (!fs.existsSync(sourceFile)) {
    return finish({ status: 'short_deslop_source_missing', instruction: '正式合并稿缺失；返回全篇组装阶段恢复，不要继续提交去 AI 暂存稿。' }, 0, args.json);
  }
  const sourceText = fs.readFileSync(sourceFile, 'utf8');
  const plan = plannedSections(root);
  const headings = sectionIndexes(text);
  const expected = plan.status === 'locked' ? Array.from({ length: plan.count }, (_, index) => index + 1) : [];
  if (plan.status !== 'locked' || headings.length !== expected.length || headings.some((value, index) => value !== expected[index])) {
    return finish({
      status: 'short_deslop_section_identity_changed',
      planned_sections: plan.count || 0,
      actual_sections: headings,
      instruction: '去 AI 味暂存稿改变了节数、节序或标题结构；恢复本轮暂存稿，只修表达，不改结构。',
    }, 0, args.json);
  }

  const pollution = runJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
  const ai = runJson(root, 'check-ai-patterns.js', ['--check', '--json', '--fail-on=blocking', stagedFile]);
  const pollutionFindings = Array.isArray(pollution.findings) ? pollution.findings : [];
  const blockingAi = (Array.isArray(ai.findings) ? ai.findings : []).filter((item) => String(item.severity || '') === 'blocking');
  if (pollutionFindings.length || blockingAi.length) {
    return finish({
      status: 'short_deslop_revision_required',
      staged_target: stagedRel,
      findings: [
        ...pollutionFindings.slice(0, 12).map((item) => ({ code: item.type || 'output_pollution', line: item.line || 0, message: item.message || '' })),
        ...blockingAi.slice(0, 12).map((item) => ({ code: item.type || 'ai_pattern', line: item.line || 0, message: item.message || '' })),
      ],
      instruction: '只在当前暂存稿修复列出的 blocking，一次修完后重跑同一 execution_command；不要扩读项目或改剧情。',
    }, 0, args.json);
  }

  const preservation = preservationCheck(sourceText, text, { exceptionReason: args.preservationException });
  if (preservation.blocking) {
    return finish({
      status: 'short_deslop_preservation_revision_required',
      visible_status: { code: 'story_function_restoration_required', label: '去 AI 后需补回剧情功能' },
      staged_target: stagedRel,
      preservation,
      instruction: preservation.repair_principle,
      next_candidates: [
        { number: 1, label: '定向补回被误删的剧情功能（推荐）', action: 'repair_staged_deslop', description: '只修改去 AI 暂存稿，补行动、反应、后果和承接；完成后重跑当前命令。' },
        { number: 2, label: '接受当前精简幅度', action: 'accept_preservation_exception', description: '仅在删减是明确的结构选择时使用，并写明理由；不要求机械补字。' },
        { number: 3, label: '放弃本轮去 AI 修改', action: 'discard_staged_deslop', description: '保留去 AI 前正式稿，重新制定更小的表达清理范围。' },
        { number: 4, label: '输入其他要求', action: 'free_text', description: '补充希望保留或恢复的具体剧情内容。' },
      ],
    }, 0, args.json);
  }

  if (!args.apply) return finish({ status: 'short_deslop_ready', visible_status: { code: 'expression_cleanup_ready', label: preservation.status === 'explicit_exception' ? '去 AI 后保真可提交（已记录结构例外）' : '去 AI 后保真通过' }, staged_target: stagedRel, canonical_sha256: hashText(text), preservation }, 0, args.json);
  const projectStateFile = path.join(root, '追踪/private-short-extension/project-state.json');
  const projectState = readJson(projectStateFile) || {};
  const acceptedByIndex = new Map((Array.isArray(projectState.accepted_sections) ? projectState.accepted_sections : [])
    .map((item) => [Number((item || {}).section_index), { ...(item || {}) }]));
  const projectedFiles = [];
  for (const section of splitSections(text)) {
    let sectionCommit;
    try {
      sectionCommit = commitAcceptedSection(root, {
        task,
        sectionIndex: section.section_index,
        title: section.title,
        text: section.body,
        metadata: {},
        projectTitle: String(projectState.project_title || projectState.working_title || projectState.title || ''),
      });
    } catch (error) {
      return finish({ status: String(error.status || 'short_deslop_section_commit_blocked'), section_index: section.section_index, detail: String(error.message || error), instruction: '已完成的逐节提交可安全复用；修复当前提交条件后重跑 execution_command，不要重新去 AI。' }, 0, args.json);
    }
    const anchorRel = `追踪/private-short-extension/section-${String(section.section_index).padStart(3, '0')}-anchor.json`;
    const anchorFile = safeProjectFile(root, anchorRel);
    const anchor = readJson(anchorFile) || {};
    atomicWriteJson(anchorFile, {
      ...anchor,
      workflow_id: workflowId,
      section_index: section.section_index,
      section_title: section.title,
      canonical_path: String(sectionCommit.canonical_path || `正文/第${String(section.section_index).padStart(3, '0')}节.md`),
      canonical_sha256: String(sectionCommit.canonical_sha256 || ''),
      section_commit_id: String(sectionCommit.commit_id || ''),
      expression_revision_at: new Date().toISOString(),
    });
    const accepted = acceptedByIndex.get(section.section_index) || { section_index: section.section_index };
    acceptedByIndex.set(section.section_index, {
      ...accepted,
      title: section.title,
      canonical_path: String(sectionCommit.canonical_path || accepted.canonical_path || ''),
      anchor_path: anchorRel,
      sha256: String(sectionCommit.canonical_sha256 || ''),
      section_commit_id: String(sectionCommit.commit_id || ''),
      length_chars: (section.body.match(/[\u3400-\u9fff]/g) || []).length,
    });
    projectedFiles.push(String(sectionCommit.canonical_path || ''), anchorRel);
  }
  atomicWriteJson(projectStateFile, {
    ...projectState,
    accepted_sections: [...acceptedByIndex.values()].sort((a, b) => Number(a.section_index) - Number(b.section_index)),
    expression_revision_at: new Date().toISOString(),
  });
  projectedFiles.push('追踪/private-short-extension/project-state.json');
  const artifactDir = `${task.task_dir}/artifacts/short-deslop-commit`;
  const manifestRel = `${artifactDir}/manifest.json`;
  atomicWriteJson(safeProjectFile(root, manifestRel), {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: VOLUME,
    chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: 'short_story_deslopped_body', required: true, staged: stagedRel, target: '正文.md' }],
    facts: [],
  });
  let commit;
  try {
    commit = matchingCommit(root, workflowId, text) || acceptTransaction(root, prepareTransaction(root, manifestRel).transaction_id);
  } catch (error) {
    return finish({ status: String(error.status || 'short_deslop_commit_blocked'), detail: String(error.message || error), instruction: '暂存稿仍保留；修复提交条件后重跑 execution_command，不要再次去 AI。' }, 0, args.json);
  }
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/${stageId}.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId,
    step_id: stageId,
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    scope: '全篇',
    outputs: ['正文.md', ...projectedFiles.filter(Boolean)],
    changed_files: ['正文.md', ...projectedFiles.filter(Boolean)],
    created_files: [],
    evidence: [{ planned_sections: plan.count, canonical_sha256: hashText(text), output_pollution: 'pass', ai_pattern_blocking: 0, preservation_status: preservation.status }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    prose_gate_result: 'pass',
    preservation_result: preservation,
    short_deslop_commit: { commit_id: String(commit.commit_id || ''), canonical_path: '正文.md', source_canonical_sha256: String(execution.deslop_source_digest || '').replace(/^sha256:/, ''), canonical_sha256: hashText(text) },
    checkpoint_state: { current_stage: stageId, completed_range: `第1-${plan.count}节全篇表达检查完成`, remaining_range: '最终检查与导出', resume_from: 'final_check' },
    next_stage_id: 'final_check',
    next_recommendation: '进入最终检查与导出。',
    handoff_summary: `已完成 ${plan.count} 节全篇表达检查；节数与节序保持不变。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  return applyResult(root, workflowId, packetFile, packetRel, args.json);
}

function plannedSections(root) {
  return resolvePlannedSectionCount({
    projectState: readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {},
    titleLock: readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {},
    outlineText: readText(path.join(root, '小节大纲.md')),
  });
}
function sectionIndexes(text) { return [...String(text || '').matchAll(/^##\s+第\s*0*(\d+)\s*节\b/gmu)].map((match) => Number(match[1])); }
function splitSections(text) {
  const source = String(text || '');
  const matches = [...source.matchAll(/^##\s+第\s*0*(\d+)\s*节(?:\s+([^\n]+))?\s*$/gmu)];
  return matches.map((match, index) => ({
    section_index: Number(match[1]),
    title: String(match[2] || '').trim() || `第${Number(match[1])}节`,
    body: source.slice(match.index + match[0].length, matches[index + 1] ? matches[index + 1].index : source.length).trim(),
  }));
}
function runJson(root, script, argv) { const run = spawnSync(process.execPath, [path.join(__dirname, script), ...argv], { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }); return parseJson(run.stdout) || { status: 'checker_failed', findings: [{ type: script, message: String(run.stderr || '').trim().slice(0, 500) }] }; }
function matchingCommit(root, workflowId, text) { const commit = (inspectChapter(root, VOLUME, 1) || {}).latest_commit; if (!commit || String(commit.workflow_id || '') !== workflowId) return null; const hash = hashText(text); const artifact = (commit.artifacts || []).find((item) => String(item.target || '') === '正文.md'); return artifact && normalizeHash(artifact.after_hash || artifact.content_hash) === hash && fs.existsSync(path.join(root, '正文.md')) && hashFile(path.join(root, '正文.md')) === hash ? commit : null; }
function applyResult(root, workflowId, packetFile, packetRel, json) { const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 }); const outcome = classifyWorkflowApply(run); const result = outcome.result; return finish({ status: outcome.applied ? 'applied' : 'apply_blocked', workflow_status: outcome.workflowStatus, workflow_id: workflowId, result_packet: packetRel, next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''), ...outcome.presentation, ...(outcome.applied ? {} : { recovery: result }) }, outcome.exitCode, json); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function hashText(value) { return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex'); }
function hashFile(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function normalizeHash(value) { return String(value || '').replace(/^sha256:/u, ''); }
function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', preservationException: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') out.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++i] || ''; else if (arg === '--accept-preservation-exception') out.preservationException = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-story-deslop-finalize.js --project-root <book> --workflow-id <id> [--accept-preservation-exception <reason>] [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-story-deslop-finalize.js --project-root <book> --workflow-id <id> [--accept-preservation-exception <reason>] [--apply] [--json]\n'); return 0; }

process.exitCode = main();
