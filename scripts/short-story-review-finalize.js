#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const {
  attachEvidenceRuntime,
  buildShortStoryEvidencePack,
  validateEditorialReviewCard,
} = require('./lib/short-story-editorial-review');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || singleUnfinishedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'full_story_review'
    || String(execution.status || '') !== 'running'
    || String(execution.stage_id || '') !== 'full_story_review') {
    return finish({ status: 'stage_action_not_applicable', expected: 'full_story_review', actual: task.current_stage || '', instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }

  const storyFile = safeProjectFile(root, '正文.md');
  const pack = attachEvidenceRuntime(buildShortStoryEvidencePack(root, { workflowId, storyPath: '正文.md' }), storyFile);
  if (pack.status !== 'ok') return finish(pack, 0, args.json);
  const artifactRoot = `${task.task_dir}/artifacts/full-story-review`;
  const evidenceRel = `${artifactRoot}/evidence-pack.json`;
  const reviewRel = `${artifactRoot}/editorial-review.json`;
  const evidenceFile = safeProjectFile(root, evidenceRel);
  const reviewFile = safeProjectFile(root, reviewRel);
  atomicWriteJson(evidenceFile, pack);

  if (!fs.existsSync(reviewFile)) {
    return finish({
      status: 'short_story_editorial_review_required',
      workflow_id: workflowId,
      evidence_pack: evidenceRel,
      review_card: reviewRel,
      instruction: '优先并行调用 story-architect 与 character-designer 做一次全篇总编辑验收；Agent 不可用时由 story-review 按同一合同 solo fallback。只读取证据包、正文、设定和小节大纲，按 review_card_schema 写入一张综合审阅卡，然后重跑同一 execution_command。不要修改正文。',
      review_card_schema: reviewCardSchema(),
    }, 0, args.json);
  }

  const card = readJson(reviewFile);
  const validation = validateEditorialReviewCard(card, pack);
  if (validation.status !== 'valid') {
    return finish({
      status: 'short_story_editorial_review_invalid',
      review_card: reviewRel,
      findings: validation.findings,
      instruction: '只修订审阅卡缺失或证据不匹配的字段，然后重跑同一 execution_command；不要重读 workflow 源码或修改正文。',
    }, 0, args.json);
  }

  const decision = String(card.decision || '');
  const reviewFindings = Array.isArray(card.findings) ? card.findings : [];
  const visibleVerdict = reviewVerdict(decision, reviewFindings);
  const passNextStage = String(task.workflow_profile || '') === 'private' || String(task.workflow_owner || '') === 'private-short-extension'
    ? 'short_deslop'
    : 'deslop';
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/full_story_review.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'full_story_review',
    step_id: 'full_story_review',
    owner_module: String(execution.owner_module || 'story-review'),
    step_status: 'completed',
    scope: '全篇',
    outputs: [evidenceRel, reviewRel],
    changed_files: [],
    created_files: [evidenceRel, reviewRel],
    evidence: [{ type: 'short_full_story_review', story_path: '正文.md', story_sha256: pack.story_sha256, review_card_path: reviewRel, review_card_sha256: hashFile(reviewFile) }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    short_full_story_review: {
      schemaVersion: String(card.schemaVersion || ''),
      decision,
      visible_verdict: visibleVerdict.code,
      visible_label: visibleVerdict.label,
      story_path: '正文.md',
      story_sha256: pack.story_sha256,
      evidence_pack_path: evidenceRel,
      review_card_path: reviewRel,
      review_card_sha256: hashFile(reviewFile),
      summary: String(card.summary || ''),
      findings: reviewFindings,
    },
    checkpoint_state: {
      current_stage: 'full_story_review',
      completed_range: '全篇总编辑验收完成',
      remaining_range: decision === 'pass' ? '表达层清理与最终发布检查' : '作者确认修订范围后回写规划与正文',
      resume_from: decision === 'pass' ? passNextStage : 'feedback_impact_sync',
    },
    next_stage_id: decision === 'pass' ? passNextStage : 'feedback_impact_sync',
    next_recommendation: decision === 'pass'
      ? `${visibleVerdict.label}，继续表达层去 AI 味。`
      : `发现 ${reviewFindings.length} 项全篇问题，进入反馈影响分析并让作者确认修订方案。`,
    handoff_summary: decision === 'pass'
      ? '全篇结构、人物弧线、身份效用、高潮结尾与标题承诺已具备进入表达清理的条件。'
      : `全篇验收建议回炉：${reviewFindings.map(item => `${item.code}:${item.scope}`).join('；')}`,
    memory_updates: [],
    result_packet_path: packetRel,
  });

  if (!args.apply) return finish({ status: 'short_story_editorial_review_ready', decision, visible_verdict: visibleVerdict, result_packet: packetRel }, 0, args.json);
  const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
  });
  const outcome = classifyWorkflowApply(run);
  return finish({
    status: outcome.applied ? 'completed' : 'apply_blocked',
    decision,
    visible_verdict: visibleVerdict,
    workflow_id: workflowId,
    result_packet: packetRel,
    workflow_status: outcome.workflowStatus,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function reviewCardSchema() {
  return {
    schemaVersion: '1.0.0',
    workflow_id: '<workflow_id>',
    story_sha256: '<evidence_pack.story_sha256>',
    decision: 'pass|revise（内部协议字段；对作者展示 visible_verdict）',
    visible_verdict: '故事层可进入表达清理|故事层可进入表达清理（有建议项）|故事层需先回炉',
    summary: '<全篇结论>',
    opening_assessment: { verdict: 'pass|concern|fail', evidence_quote: '<正文原句>', reason: '<是否场景化、是否信息过载>' },
    section_function_matrix: [{ section_index: 1, structural_role: '<本节职责>', function_verdict: 'pass|concern|fail', evidence_quote: '<正文原句>', note: '<篇幅与功能判断>' }],
    character_arc_matrix: [{ character: '<人物>', desire: '<想要什么>', active_action: '<主动行动>', cost: '<代价>', change: '<前后变化>', verdict: 'pass|concern|fail', evidence_quotes: ['<正文原句>'] }],
    identity_payoff_matrix: [{ identity_or_trait: '<职业/能力/缺陷/身份>', setup_quote: '<前文原句>', payoff_quote: '<后文原句>', verdict: 'pass|concern|fail' }],
    identity_not_applicable_reason: '<确实不适用时填写>',
    climax_ending_assessment: { verdict: 'pass|concern|fail', climax_quote: '<高潮原句>', ending_quote: '<结尾原句>', reason: '<高潮跑道、责任后果、标题兑现>' },
    findings: [{ code: '<稳定代码>', severity: 'S1|S2|S3|S4', scope: '<受影响小节/规划层>', evidence_quote: '<正文原句>', repair_direction: '<回写方向>' }],
  };
}

function reviewVerdict(decision, findings) {
  if (decision === 'revise') return { code: 'revision_required', label: '故事层需先回炉' };
  if ((findings || []).length) return { code: 'story_ready_with_advisory', label: '故事层可进入表达清理（有建议项）' };
  return { code: 'story_ready', label: '故事层可进入表达清理' };
}

function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function hashFile(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') out.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-story-review-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-story-review-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n'); return 0; }

process.exitCode = main();
