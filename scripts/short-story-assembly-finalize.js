#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, inspectChapter, prepareTransaction } = require('./lib/chapter-commit-store');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { buildPendingAction, buildShortDraftPendingAction, decoratePendingAction } = require('./lib/workflow-action-renderer');
const { initializeAssemblyIntegrityRevisionQueue } = require('./lib/short-feedback-revision-queue');
const { validateShortSectionAcceptanceProof } = require('./lib/short-section-acceptance-proof');
const { resolvePlannedSectionCount } = require('./lib/short-workflow-state');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson, atomicWriteText } = require('./lib/workflow-state-store');

const ASSEMBLY_VOLUME = '短篇发布稿';

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  if (String(task.current_stage || '') !== 'full_story_assembly') {
    return finish({ status: 'stage_action_not_applicable', expected: 'full_story_assembly', actual: task.current_stage || '', instruction: '重新读取当前任务的 execution_command，不要运行旧阶段命令。' }, 0, args.json);
  }
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'full_story_assembly') {
    return finish({ status: 'stage_execution_not_ready', instruction: '先由工作流启动全文组装阶段。' }, 0, args.json);
  }

  const stateFile = path.join(root, '追踪/private-short-extension/project-state.json');
  const state = readJson(stateFile) || {};
  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const plan = resolvePlannedSectionCount({ projectState: state, titleLock, outlineText });
  if (plan.status !== 'locked') {
    return finish({
      status: plan.status === 'conflict' ? 'short_section_plan_conflict' : 'short_section_plan_missing',
      instruction: '先确认唯一的全篇小节数，再重新组装；不要猜测节数。',
      plan_evidence: plan.candidates || [],
    }, 0, args.json);
  }

  const accepted = new Map((Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
    .map((item) => [Number((item || {}).section_index), item]));
  const missing = [];
  const invalid = [];
  const sectionTexts = [];
  for (let sectionIndex = 1; sectionIndex <= plan.count; sectionIndex += 1) {
    const item = accepted.get(sectionIndex);
    if (!item) {
      missing.push(sectionIndex);
      continue;
    }
    const proof = validateShortSectionAcceptanceProof({
      projectRoot: root,
      workflowId,
      requireCommit: true,
      proof: {
        workflow_id: workflowId,
        section_index: sectionIndex,
        anchor_path: item.anchor_path,
        canonical_path: item.canonical_path,
        canonical_sha256: item.sha256,
        section_commit_id: item.section_commit_id,
      },
    });
    if (proof.status !== 'accepted') {
      invalid.push({ section_index: sectionIndex, reason: proof.code || 'invalid_acceptance' });
      continue;
    }
    sectionTexts.push(readText(path.join(root, proof.canonical_path)).trim());
  }
  const outsidePlan = [...accepted.keys()].filter((value) => Number.isInteger(value) && value > plan.count).sort((a, b) => a - b);
  if (missing.length || invalid.length || outsidePlan.length) {
    const legacyMigrationAvailable = !missing.length && !outsidePlan.length
      && invalid.length > 0
      && invalid.every((finding) => {
        const item = accepted.get(Number(finding.section_index));
        const expectedPath = `正文/第${String(finding.section_index).padStart(3, '0')}节.md`;
        return item && (String(item.canonical_path || '') !== expectedPath || !String(item.section_commit_id || ''));
      });
    const recovery = legacyMigrationAvailable
      ? { status: 'legacy_migration_required', current_stage: task.current_stage, visible_response: '' }
      : persistAssemblyRecovery(root, task, { missing, invalid, outsidePlan });
    return finish({
      status: 'short_story_assembly_blocked',
      planned_sections: plan.count,
      missing_sections: missing,
      invalid_sections: invalid,
      outside_plan_sections: outsidePlan,
      legacy_migration_available: legacyMigrationAvailable,
      next_candidates: [
        { number: 1, label: legacyMigrationAvailable ? '迁移旧小节事实源（推荐）' : '修复缺失或失效的小节（推荐）' },
        { number: 2, label: '查看小节验收明细' },
        { number: 3, label: '暂停并保存断点' },
        { number: 4, label: '输入其他要求' },
      ],
      migration_command: legacyMigrationAvailable
        ? `node scripts/short-section-artifact-migrate.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --confirm --json`
        : '',
      recovery_status: recovery.status,
      recovery_stage: recovery.current_stage,
      visible_response: recovery.visible_response,
    }, 0, args.json);
  }

  const assembledText = `${sectionTexts.join('\n\n')}\n`;
  if (!args.apply) {
    return finish({
      status: 'short_story_assembly_ready',
      workflow_id: workflowId,
      planned_sections: plan.count,
      assembled_sections: plan.count,
      canonical_sha256: hashText(assembledText),
      next_action: '使用 --apply 执行受控合稿。',
    }, 0, args.json);
  }
  const taskArtifactDir = `${task.task_dir}/artifacts/full-story-assembly`;
  const stagedRel = `${taskArtifactDir}/正文.md`;
  const manifestRel = `${taskArtifactDir}/manifest.json`;
  atomicWriteText(safeProjectFile(root, stagedRel), assembledText);
  atomicWriteJson(safeProjectFile(root, manifestRel), {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: ASSEMBLY_VOLUME,
    chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: 'short_story_release_body', required: true, staged: stagedRel, target: '正文.md' }],
    facts: [],
  });

  let commit;
  try {
    commit = matchingAssemblyCommit(root, workflowId, assembledText)
      || acceptTransaction(root, prepareTransaction(root, manifestRel).transaction_id);
  } catch (error) {
    return finish({
      status: String((error || {}).status || 'short_story_assembly_commit_blocked'),
      detail: String((error || {}).message || error || ''),
      instruction: '已采用的小节未丢失；修复提交条件后重试全文组装，不要重新写正文。',
    }, 0, args.json);
  }

  const outputHash = hashText(assembledText);
  const nextStage = 'full_story_review';
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/full_story_assembly.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'full_story_assembly',
    step_id: 'full_story_assembly',
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: ['正文.md'],
    changed_files: ['正文.md'],
    created_files: ['正文.md'],
    evidence: [{ planned_sections: plan.count, assembled_sections: plan.count, canonical_sha256: outputHash }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    short_story_assembly: {
      planned_sections: plan.count,
      assembled_sections: plan.count,
      canonical_path: '正文.md',
      canonical_sha256: outputHash,
      assembly_commit_id: String(commit.commit_id || ''),
      next_stage_id: nextStage,
    },
    checkpoint_state: { current_stage: 'full_story_assembly', completed_range: `第1-${plan.count}节已合稿`, remaining_range: '全篇总编辑验收、表达清理与最终检查', resume_from: nextStage },
    next_stage_id: nextStage,
    next_recommendation: '进入全篇总编辑验收；先检查故事结构、人物弧线与结尾兑现，再做表达层清理。',
    handoff_summary: `已按锁定顺序组装 ${plan.count} 节；无缺节、重复节或计划外小节。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });

  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root,
    '--workflow-id', workflowId, '--result', packetFile, '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  const applyResult = outcome.result;
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    result_packet: packetRel,
    planned_sections: plan.count,
    next_stage: String(applyResult.current_stage || ((applyResult.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: applyResult }),
  }, outcome.exitCode, args.json);
}

function persistAssemblyRecovery(root, task, findings) {
  const missing = Array.isArray(findings.missing) ? findings.missing : [];
  const invalid = Array.isArray(findings.invalid) ? findings.invalid : [];
  const outsidePlan = Array.isArray(findings.outsidePlan) ? findings.outsidePlan : [];
  try {
    const next = mutateTaskAuthority(root, task.workflow_id, Number(task.state_version || 0), (draft) => {
      draft.stage_execution = null;
      draft.status = 'waiting_user';
      draft.next_stop_reason = 'assembly_integrity_repair_required';
      if (outsidePlan.length) {
        draft.current_stage = 'section_plan_lock';
        draft.scope = '全篇结构';
        draft.pending_action = buildPendingAction(null, {
          stage_id: 'section_plan_lock',
          label: '重新确认总小节与计划外小节',
          description: `发现计划外小节：${outsidePlan.join('、')}。先确认保留、并入或移除，再继续合稿。`,
          risk_level: 'medium',
          requires_user_confirm: true,
        });
        return draft;
      }
      const initialized = initializeAssemblyIntegrityRevisionQueue(draft, {
        missing_sections: missing,
        invalid_sections: invalid,
      });
      const current = Number((initialized.queue || {}).current_section_index || 0);
      const missingCurrent = missing.includes(current);
      if (missingCurrent) {
        draft.current_stage = 'next_section_brief';
        draft.pending_action = decoratePendingAction({
          id: `pa-assembly-missing-section-${current}`,
          question: `全文组装发现第 ${current} 节尚未形成已采用版本`,
          options: [
            { number: 1, action_id: 'continue_next_stage', target_stage: 'next_section_brief', label: `补齐并采用第 ${current} 节（推荐）`, risk_level: 'medium', requires_user_confirm: true },
            { number: 2, action_id: 'inspect_current_state', label: '查看缺失小节与组装依据', risk_level: 'low', requires_user_confirm: false },
            { number: 3, action_id: 'pause', label: '暂停并保存断点', risk_level: 'low', requires_user_confirm: false },
            { number: 4, action_id: 'free_text', label: '输入其他要求', risk_level: 'low', requires_user_confirm: false },
          ],
          free_text_enabled: true,
        });
      } else {
        draft.current_stage = 'draft_section';
        draft.pending_action = buildShortDraftPendingAction({ stage_id: 'draft_section', risk_level: 'medium' }, draft);
      }
      draft.recommended_next = (draft.pending_action.options || []).map(option => ({
        number: option.number,
        action_id: option.action_id,
        label: option.label,
      }));
      return draft;
    }, { owner: 'short-story-assembly-recovery' });
    return {
      status: 'assembly_recovery_persisted',
      current_stage: next.current_stage,
      visible_response: renderRecovery(next),
    };
  } catch (error) {
    return {
      status: String((error || {}).code || 'assembly_recovery_persist_failed'),
      current_stage: String(task.current_stage || ''),
      visible_response: '组装问题已识别，但任务状态刚刚发生变化。请重新打开当前任务查看最新恢复队列。',
    };
  }
}

function renderRecovery(task) {
  const queue = task.feedback_revision_queue || {};
  const sections = Array.isArray(queue.affected_sections) ? queue.affected_sections.join('、') : '';
  const options = ((task.pending_action || {}).options || [])
    .map(option => `${option.number}. ${option.label}`)
    .join('\n');
  return [
    sections ? `全文组装发现第 ${sections} 节需要重新验收；已建立复检队列，不会重写其他已采用小节。` : '全文组装发现结构范围冲突，已停在对应恢复任务。',
    options,
    '回复数字选择。',
  ].filter(Boolean).join('\n');
}

function matchingAssemblyCommit(root, workflowId, text) {
  const inspected = inspectChapter(root, ASSEMBLY_VOLUME, 1);
  const commit = inspected.latest_commit;
  const hash = hashText(text);
  if (!commit || String(commit.workflow_id || '') !== workflowId) return null;
  const artifact = (commit.artifacts || []).find((item) => String(item.target || '') === '正文.md');
  if (!artifact || normalizeHash(artifact.after_hash || artifact.content_hash) !== hash) return null;
  const canonicalFile = path.join(root, '正文.md');
  return fs.existsSync(canonicalFile) && hashFile(canonicalFile) === hash
    ? { status: 'accepted', commit_id: commit.commit_id, already_accepted: true }
    : null;
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', apply: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++index] || '';
    else if (arg === '--apply' || arg === '--write') args.apply = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}

function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); if (file !== root && !file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe path: ${rel}`); return file; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function hashText(text) { return crypto.createHash('sha256').update(String(text || ''), 'utf8').digest('hex'); }
function hashFile(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function normalizeHash(value) { return String(value || '').replace(/^sha256:/, ''); }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : `${value.status}\n`}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-story-assembly-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-story-assembly-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n'); return 0; }

process.exitCode = main();
