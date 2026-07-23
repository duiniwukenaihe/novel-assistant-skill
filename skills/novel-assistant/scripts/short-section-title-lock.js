#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { advanceShortPlanRevision } = require('./lib/short-project-state');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const outlineFile = path.join(root, args.outline || '小节大纲.md');
  if (!fs.existsSync(outlineFile)) return finish({ status: 'short_outline_missing', outline: relative(root, outlineFile), instruction: '先完成全篇小节大纲，再确认标题。' }, 0, args.json);
  const outline = fs.readFileSync(outlineFile, 'utf8');
  const sections = parseSectionTitles(outline);
  if (!sections.length) return finish({ status: 'short_section_titles_missing', outline: relative(root, outlineFile), instruction: '在全篇小节大纲中补齐小节条目；允许明确选择无标题。' }, 0, args.json);
  const titleFindings = validateSectionTitles(sections);
  if (titleFindings.length) {
    return finish({
      status: 'short_section_title_plan_invalid',
      outline: relative(root, outlineFile),
      findings: titleFindings,
      next_candidates: [
        { number: 1, label: '修正小节序号或重复标题（推荐）' },
        { number: 2, label: '重新查看全篇标题清单' },
        { number: 3, label: '暂停并保存断点' },
        { number: 4, label: '输入其他要求' },
      ],
    }, 0, args.json);
  }
  const digest = sha256(JSON.stringify(sections));
  const lockRel = '追踪/private-short-extension/section-title-lock.json';
  const authority = args.workflowId ? resolveTaskAuthority(root, args.workflowId) : null;
  const task = authority && authority.status === 'ok' ? authority.task : null;
  if (task && String(task.current_stage || '') === 'section_plan_lock') {
    const boundaryFindings = validateSectionPlanBoundary(outline, sections, task);
    if (boundaryFindings.length) {
      const options = [
        { number: 1, label: '补齐总小节与完稿边界（推荐）', action: 'revise_section_plan' },
        { number: 2, label: '查看缺失项与当前大纲', action: 'inspect_current_state' },
        { number: 3, label: '暂停并保存断点', action: 'pause' },
        { number: 4, label: '输入其他要求', action: 'free_text' },
      ];
      return finish({
        status: 'short_section_plan_boundary_incomplete',
        outline: relative(root, outlineFile),
        findings: boundaryFindings,
        next_candidates: options,
        visible_response: {
          render_mode: 'text_numbers', status: 'workflow_choice_required', selection_contract: 'execute_command_or_route_intent', options,
          text: `总小节与完稿边界尚未锁定：\n${boundaryFindings.map((item) => `- ${item.message}`).join('\n')}\n\n1. 补齐总小节与完稿边界（推荐）\n2. 查看缺失项与当前大纲\n3. 暂停并保存断点\n4. 输入其他要求\n\n回复数字选择，也可以直接输入修改意见。`,
        },
      }, 0, args.json);
    }
  }
  const existingLock = readJson(path.join(root, lockRel)) || {};
  if (!args.confirm && task && String(task.current_stage || '') === 'section_plan_lock'
      && reusableConfirmedLock(existingLock, digest, sections)) {
    return persistLockAndContinue({ root, args, task, sections, digest, lockRel, outlineFile, reused: true });
  }
  if (!args.confirm) {
    const workflowArg = args.workflowId ? ` --workflow-id ${JSON.stringify(args.workflowId)}` : '';
    const confirmCommand = `node scripts/short-section-title-lock.js --project-root .${workflowArg} --digest ${JSON.stringify(digest)} --confirm --json`;
    if (task && String(task.current_stage || '') === 'section_plan_lock') {
      persistTitlePreview(root, task, sections, digest, confirmCommand);
    }
    const options = [
      { number: 1, label: '确认当前总小节与标题（推荐）', interaction_mode: 'execute_command', execution_command: confirmCommand },
      { number: 2, label: '修改小节标题或总节数', interaction_mode: 'semantic_only', action: 'revise_section_plan' },
      { number: 3, label: '暂停并保存断点', interaction_mode: 'execute_command', execution_command: 'node scripts/workflow-state-machine.js resolve-action --project-root . --input 3 --json' },
      { number: 4, label: '输入其他要求', interaction_mode: 'semantic_only', action: 'free_text' },
    ];
    return finish({
      status: 'awaiting_section_title_confirmation',
      outline: relative(root, outlineFile),
      digest,
      sections,
      instruction: '请逐项确认或先修改小节大纲中的标题。无标题也要明确确认，此时后续只显示“第 N 节”。',
      confirm_command: confirmCommand,
      next_candidates: options,
      visible_response: {
        render_mode: 'text_numbers',
        status: 'workflow_choice_required',
        selection_contract: 'execute_command_or_route_intent',
        options,
        text: renderTitleConfirmation(sections, options),
      },
    }, 0, args.json);
  }
  if (!args.workflowId) {
    return finish({
      status: 'blocked_short_workflow_id_required',
      instruction: '标题确认会写入项目状态，必须使用当前工作流菜单提供的确认命令。',
    }, 2, args.json);
  }
  const confirmedAuthority = resolveTaskAuthority(root, args.workflowId);
  if (confirmedAuthority.status !== 'ok') {
    return finish({ status: confirmedAuthority.status, instruction: confirmedAuthority.message || '找不到可信的短篇任务快照。' }, 2, args.json);
  }
  if (!['short_write', 'short_startup', 'private_short_startup'].includes(String(confirmedAuthority.task.workflow_type || ''))) {
    return finish({ status: 'blocked_short_title_lock_wrong_workflow', workflow_id: args.workflowId }, 2, args.json);
  }
  if (!args.digest || args.digest !== digest) return finish({ status: 'short_section_title_digest_changed', expected_digest: digest, actual_digest: args.digest || '', sections, instruction: '大纲已变化，请重新展示标题清单并确认。' }, 0, args.json);
  return persistLockAndContinue({ root, args, task: confirmedAuthority.task, sections, digest, lockRel, outlineFile, reused: false });
}

function persistLockAndContinue({ root, args, task, sections, digest, lockRel, outlineFile, reused }) {
  let projectState;
  try {
    projectState = advanceShortPlanRevision(root, {
      workflowId: args.workflowId,
      outlinePath: relative(root, outlineFile),
      plannedSections: sections.length,
    });
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_state_blocked'), workflow_id: args.workflowId, instruction: '项目身份或规划版本不可信，先从当前短篇任务恢复，不要确认旧标题清单。' }, 0, args.json);
  }
  const lockFile = path.join(root, lockRel);
  atomicWriteJson(lockFile, {
    schema_version: '1.0.0',
    status: 'confirmed',
    workflow_id: args.workflowId,
    project_id: projectState.project_id,
    plan_revision: projectState.plan_revision,
    planned_sections: projectState.planned_sections,
    source_outline: relative(root, outlineFile),
    source_digest: digest,
    confirmed_at: new Date().toISOString(),
    sections: sections.map((item) => ({ ...item, confirmed: true, title_source: 'user_confirmed_outline' })),
  });
  if (String(task.current_stage || '') === 'section_plan_lock') {
    return completeSectionPlanLock({ root, args, task, sections, digest, lockRel, projectState, reused });
  }
  const refreshed = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'),
    'refresh-short-title-lock',
    '--project-root', root,
    '--workflow-id', args.workflowId,
    '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 1024 * 1024 });
  const workflowResume = parseJson(refreshed.stdout) || {
    status: 'blocked_short_title_lock_refresh_failed',
    message: String(refreshed.stderr || '').trim().slice(0, 500),
  };
  const ok = refreshed.status === 0 && workflowResume.status === 'short_section_titles_bound';
  return finish({
    status: ok ? 'section_titles_confirmed_and_bound' : 'section_titles_confirmed_workflow_refresh_blocked',
    lock_path: lockRel,
    digest,
    sections,
    workflow_resume: workflowResume,
  }, ok ? 0 : 2, args.json);
}

function completeSectionPlanLock({ root, args, task, sections, digest, lockRel, projectState, reused }) {
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'section_plan_lock') {
    return finish({ status: 'blocked_short_title_lock_stage_not_running', instruction: '标题锁已保留；请从当前短篇任务恢复锁定阶段。' }, 0, args.json);
  }
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/section_plan_lock.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_short_title_lock_packet_path_unsafe' }, 2, args.json);
  atomicWriteJson(packetFile, {
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'section_plan_lock',
    step_id: 'section_plan_lock',
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [lockRel],
    changed_files: [lockRel, '追踪/private-short-extension/project-state.json'],
    created_files: [],
    evidence: [{
      title_lock_digest: digest,
      planned_sections: sections.length,
      project_id: String(projectState.project_id || ''),
      plan_revision: Number(projectState.plan_revision || 0),
      reused_confirmed_lock: Boolean(reused),
    }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'section_plan_lock', completed_range: `已锁定 ${sections.length} 节`, remaining_range: '进入结构影响审计', resume_from: '' },
    handoff_summary: `总小节数与 ${sections.length} 个小节标题已锁定。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', String(task.workflow_id || ''), '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'section_plan_locked' : 'section_plan_lock_apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: String(task.workflow_id || ''),
    planned_sections: sections.length,
    lock_path: lockRel,
    digest,
    reused_confirmed_lock: Boolean(reused),
    result_packet: packetRel,
    next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function persistTitlePreview(root, task, sections, digest, confirmCommand) {
  try {
    mutateTaskAuthority(root, String(task.workflow_id || ''), Number(task.state_version || 0), (next) => {
      next.stage_execution = { ...(next.stage_execution || {}) };
      next.stage_execution.execution_command = confirmCommand;
      next.stage_execution.context_read_command = '';
      next.stage_execution.title_lock_preview = { digest, sections };
      next.stage_execution.resume_hint = `请确认 ${sections.length} 个小节标题；回复 1 采用当前清单，回复 2 修改标题或总节数，回复 3 暂停，回复 4 输入其他要求。`;
      return next;
    });
  } catch (_) {
    // Preview remains usable in the current turn. A concurrent task mutation
    // will force the next invocation to rebuild the digest before confirming.
  }
}

function reusableConfirmedLock(lock, digest, sections) {
  if (String((lock || {}).status || '') !== 'confirmed' || String((lock || {}).source_digest || '') !== digest) return false;
  const locked = Array.isArray((lock || {}).sections) ? lock.sections : [];
  if (locked.length !== sections.length || locked.some((item) => item.confirmed !== true)) return false;
  return locked.every((item, index) => Number(item.section_index) === Number(sections[index].section_index)
    && String(item.title || '') === String(sections[index].title || ''));
}

function renderTitleConfirmation(sections, options) {
  const lines = ['请确认全篇总小节与标题：', ''];
  for (const section of sections) lines.push(`- 第 ${section.section_index} 节：${section.title || '（无标题）'}`);
  lines.push('', ...options.map((option) => `${option.number}. ${option.label}`), '', '回复数字选择，也可以直接输入修改意见。');
  return lines.join('\n');
}

function parseSectionTitles(text) {
  const rows = [];
  for (const line of String(text || '').split(/\r?\n/)) {
    const match = line.trim().match(/^#{2,4}\s*第\s*0*(\d+)\s*节(?:\s*[:：·-]\s*(.*))?$/u);
    if (!match) continue;
    rows.push({ section_index: Number(match[1]), title: String(match[2] || '').trim() });
  }
  return rows.sort((a, b) => a.section_index - b.section_index);
}

function validateSectionTitles(sections) {
  const findings = [];
  const indices = sections.map((item) => Number(item.section_index));
  const duplicateIndices = [...new Set(indices.filter((value, index) => indices.indexOf(value) !== index))];
  if (duplicateIndices.length) findings.push({ code: 'duplicate_section_index', section_indices: duplicateIndices });
  const uniqueIndices = [...new Set(indices)].sort((a, b) => a - b);
  const expected = Array.from({ length: uniqueIndices.length }, (_, index) => index + 1);
  const missing = expected.filter((value) => !uniqueIndices.includes(value));
  if (uniqueIndices[0] !== 1 || missing.length) findings.push({ code: 'section_sequence_gap', missing_sections: missing, actual_sections: uniqueIndices });
  const titleGroups = new Map();
  for (const item of sections) {
    const title = String(item.title || '').trim();
    if (!title) continue;
    if (!titleGroups.has(title)) titleGroups.set(title, []);
    titleGroups.get(title).push(Number(item.section_index));
  }
  for (const [title, sectionIndices] of titleGroups.entries()) {
    if (sectionIndices.length > 1) findings.push({ code: 'duplicate_section_title', title, section_indices: sectionIndices });
  }
  return findings;
}

function validateSectionPlanBoundary(outline, sections, task = {}) {
  const text = String(outline || '');
  const findings = [];
  const totalMatch = text.match(/总小节数\s*[：:]\s*(\d+)\s*节?/u);
  if (!totalMatch) findings.push({ code: 'planned_section_count_missing', message: '缺少“总小节数”。' });
  else if (Number(totalMatch[1]) !== sections.length) findings.push({ code: 'planned_section_count_mismatch', message: `总小节数写为 ${totalMatch[1]}，实际标题清单为 ${sections.length} 节。` });
  if (!/(?:目标总字数|全篇目标字数|目标字数带)\s*[：:]/u.test(text)) findings.push({ code: 'target_length_band_missing', message: '缺少全篇目标字数带。' });
  if (!hasPublicationShape(text, task)) findings.push({ code: 'publication_shape_missing', message: '缺少发布形态。' });
  const sectionBlocks = splitSectionBlocks(text);
  for (const section of sections) {
    const block = sectionBlocks.get(Number(section.section_index)) || '';
    if (!hasExecutableSectionFunction(block)) findings.push({ code: 'section_function_missing', section_index: section.section_index, message: `第 ${section.section_index} 节缺少结构功能。` });
  }
  const last = sections.length ? sectionBlocks.get(Number(sections[sections.length - 1].section_index)) || '' : '';
  if (!/(?:终局|结尾|收束|责任|后果|兑现)/u.test(last)) findings.push({ code: 'completion_boundary_missing', message: '最后一节缺少终局兑现或完稿收束条件。' });
  return findings;
}

function hasPublicationShape(text, task = {}) {
  if (/(?:发布形态|成稿形态|交付形态)\s*[：:]/u.test(String(text || ''))) return true;
  return ['short_write', 'short_startup', 'private_short_startup'].includes(String(task.workflow_type || ''));
}

function hasExecutableSectionFunction(block) {
  const text = String(block || '');
  if (/(?:结构功能|本节功能|小节职责)\s*[：:]/u.test(text)) return true;
  const hasScene = /(?:承接与场景动作|场景动作|关键动作|因果推进)\s*[：:]/u.test(text);
  const hasChoice = /(?:主角选择与兑现|主角选择|角色选择|决定性行动)\s*[：:]/u.test(text);
  const hasOutcome = /(?:本节兑现|关系后果|关系收束|代价与钩子|终局兑现|主题回扣(?:与结尾钩子)?)\s*[：:]/u.test(text);
  return hasScene && hasChoice && hasOutcome;
}

function splitSectionBlocks(text) {
  const map = new Map();
  const matches = [...String(text || '').matchAll(/^#{2,4}\s*第\s*0*(\d+)\s*节(?:\s*[:：·-]\s*.*)?$/gmu)];
  for (let index = 0; index < matches.length; index += 1) {
    const start = matches[index].index;
    const end = index + 1 < matches.length ? matches[index + 1].index : String(text || '').length;
    map.set(Number(matches[index][1]), String(text || '').slice(start, end));
  }
  return map;
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', outline: '', digest: '', confirm: false, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--outline') args.outline = argv[++i] || '';
    else if (arg === '--digest') args.digest = argv[++i] || '';
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}
function printHelp() { process.stdout.write('Usage: node short-section-title-lock.js --project-root <book> [--workflow-id <id>] [--outline 小节大纲.md] [--digest sha256 --confirm] [--json]\n'); return 0; }

function sha256(value) { return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex'); }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function safeProjectFile(root, relativePath) { const value=String(relativePath||'').replace(/\\/g,'/').replace(/^\.\//,''); if(!value||path.isAbsolute(value)||value.split('/').includes('..')) return ''; const file=path.resolve(root,value); return file.startsWith(`${path.resolve(root)}${path.sep}`)?file:''; }
function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-title-lock.js --project-root <book> [--workflow-id <id>] [--outline 小节大纲.md] [--digest sha256 --confirm] [--json]\n`); process.exit(2); }

process.exitCode = main();
