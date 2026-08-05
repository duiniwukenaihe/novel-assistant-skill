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
  validateReaderResponseCard,
  validateEditorialReviewCard,
} = require('./lib/short-story-editorial-review');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { resolveSessionId } = require('./workflow-session-id');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || singleUnfinishedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  const task = authority.task;
  if (Number(task.engine_version) === 3) return finish({ status: 'v3_engine_apply_required', workflow_id: workflowId, instruction: 'V3 任务必须调用全篇收束共享 service，并通过 V3 Engine 应用 StageResult。' }, 2, args.json);
  const execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'full_story_review'
    || String(execution.status || '') !== 'running'
    || String(execution.stage_id || '') !== 'full_story_review') {
    return finish({ status: 'stage_action_not_applicable', expected: 'full_story_review', actual: task.current_stage || '', instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }

  const storyFile = safeProjectFile(root, '正文.md');
  const pack = attachEvidenceRuntime(buildShortStoryEvidencePack(root, { workflowId, storyPath: '正文.md' }), storyFile);
  if (pack.status !== 'ok') return finish(pack, 0, args.json);
  const stageAttemptId = safeSegment(execution.stage_attempt_id || 'legacy-attempt');
  const session = resolveSessionId();
  const sessionKey = crypto.createHash('sha256').update(String(session.session_id || 'session')).digest('hex').slice(0, 12);
  const artifactRoot = `${task.task_dir}/artifacts/full-story-review/attempts/${stageAttemptId}`;
  const sessionRoot = `${artifactRoot}/sessions/${sessionKey}`;
  const evidenceRel = `${artifactRoot}/evidence-pack.json`;
  const readerCandidateRel = `${sessionRoot}/reader-response.json`;
  const reviewCandidateRel = `${sessionRoot}/editorial-review.json`;
  const acceptedReaderRel = `${artifactRoot}/accepted/reader-response.json`;
  const acceptedReviewRel = `${artifactRoot}/accepted/editorial-review.json`;
  const validationStateRel = `${artifactRoot}/validation-state.json`;
  const evidenceFile = safeProjectFile(root, evidenceRel);
  const readerCandidateFile = safeProjectFile(root, readerCandidateRel);
  const reviewCandidateFile = safeProjectFile(root, reviewCandidateRel);
  const acceptedReaderFile = safeProjectFile(root, acceptedReaderRel);
  const acceptedReviewFile = safeProjectFile(root, acceptedReviewRel);
  const validationStateFile = safeProjectFile(root, validationStateRel);
  fs.mkdirSync(path.dirname(readerCandidateFile), { recursive: true });
  fs.mkdirSync(path.dirname(acceptedReaderFile), { recursive: true });
  atomicWriteJson(evidenceFile, pack);

  let readerResponse = readJson(acceptedReaderFile);
  if (!readerResponse) {
    const readerCandidate = readJson(readerCandidateFile);
    const legacyCombinedCard = readJson(reviewCandidateFile);
    const submittedReader = readerCandidate || ((legacyCombinedCard || {}).reader_response || null);
    if (!submittedReader) {
      return finish({
        status: 'short_story_reader_response_required',
        workflow_id: workflowId,
        evidence_pack: evidenceRel,
        reader_response_card: readerCandidateRel,
        review_card: reviewCandidateRel,
        instruction: '调用 professional-reader 只读盲读正文，只写 reader_response_card。第一遍不得读取大纲、设定或旧审阅报告，不给修复方案。完成后重跑同一 execution_command。',
        reader_response_schema: readerResponseSchema(),
      }, 0, args.json);
    }
    const readerValidation = validateReaderResponseCard(submittedReader, pack);
    if (readerValidation.status !== 'valid') {
      return finish(invalidReviewResponse({
        kind: 'reader_response',
        findings: readerValidation.findings,
        candidateRel: readerCandidate ? readerCandidateRel : reviewCandidateRel,
        validationStateFile,
      }), 0, args.json);
    }
    readerResponse = submittedReader;
    atomicWriteJson(acceptedReaderFile, readerResponse);
  }

  if (!fs.existsSync(reviewCandidateFile)) {
    return finish({
      status: 'short_story_editorial_review_required',
      workflow_id: workflowId,
      evidence_pack: evidenceRel,
      reader_response_card: acceptedReaderRel,
      review_card: reviewCandidateRel,
      instruction: '并行调用 story-architect 与 character-designer 做总编辑验收；只读取证据包、正文、设定、小节大纲和已接受的 reader_response_card，按 review_card_schema 写入编辑裁决卡。不要重复生成读者卡，不要修改正文。完成后重跑同一 execution_command。',
      review_card_schema: editorialReviewSchema(),
    }, 0, args.json);
  }

  const card = readJson(reviewCandidateFile);
  const validation = validateEditorialReviewCard(card, pack, { readerResponse });
  if (validation.status !== 'valid') {
    return finish(invalidReviewResponse({
      kind: 'editorial_review',
      findings: validation.findings,
      candidateRel: reviewCandidateRel,
      validationStateFile,
    }), 0, args.json);
  }
  atomicWriteJson(acceptedReviewFile, card);

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
    outputs: [evidenceRel, acceptedReaderRel, acceptedReviewRel],
    changed_files: [],
    created_files: [evidenceRel, acceptedReaderRel, acceptedReviewRel],
    evidence: [{ type: 'short_full_story_review', story_path: '正文.md', story_sha256: pack.story_sha256, reader_response_path: acceptedReaderRel, review_card_path: acceptedReviewRel, review_card_sha256: hashFile(acceptedReviewFile) }],
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
      reader_response_path: acceptedReaderRel,
      review_card_path: acceptedReviewRel,
      review_card_sha256: hashFile(acceptedReviewFile),
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
  const run = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--compact', '--json'], {
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

function readerResponseSchema() {
  return {
    reader_profile: { target_platform: '<用户确认或项目配置；未知写未确认>', platform_mode: 'free_feed_mobile|paid_serial_core|relationship_community|story_answer|general_fiction', genre_lens: ['<题材观察重点>'], style_lens: ['fast_punchy|restrained_realism|relationship_tension|suspense_gap|immersive_world|light_humor|lyrical_atmosphere'], reading_scene: 'mobile_continuous', profile_basis: '<用户确认/项目文件/扫榜拆文产物路径/通用画像>' },
    section_reader_response: [{ section_index: 1, engagement: 'engaged|wavering|drop_risk', felt_emotion: '<实际感受>', reader_question: '<此刻最想知道什么>', evidence_quote: '<正文原句>' }],
    drop_off_points: [{ section_index: 1, evidence_quote: '<正文原句>', reader_reaction: '<为什么想停>', severity: 'high|medium|low' }],
    character_impressions: [{ character: '<人物>', first_impression: '<初印象>', later_impression: '<后续印象>', trust_change: 'up|down|flat', evidence_quotes: ['<正文原句>'] }],
    identity_continuity: [{ identity_or_trait: '<职业/能力/缺陷/习惯>', visibility: 'present|fading|abandoned', reader_effect: '<持续参与或消失造成的阅读感受>', evidence_quotes: ['<前文原句>', '<后文原句>'] }],
    supporting_character_reality: [{ character: '<重要配角>', felt_status: 'alive|thin|functional', apparent_want: '<读者能感到的自身欲望>', decisive_choice: '<独立选择>', relationship_effect: '<对关系造成的变化>', evidence_quotes: ['<正文原句>'] }],
    reveal_aftershock: [{ reveal_section_index: 1, revelation: '<关键揭示>', immediate_reader_shift: '<揭示后期待怎样改变>', consequence_seen: 'yes|partial|no', later_evidence_quotes: ['<后续正文原句>'] }],
    promise_response: { title_expectation: '<标题带来的期待>', payoff_status: 'fulfilled|partial|missed', evidence_quotes: ['<正文原句>'], reader_aftertaste: '<读完余味>' },
    final_reader_state: { would_continue_or_recommend: 'yes|maybe|no', strongest_pull: '<最大吸引力>', biggest_resistance: '<最大阻力>' },
  };
}

function editorialReviewSchema() {
  return {
    schemaVersion: '1.0.0',
    workflow_id: '<workflow_id>',
    story_sha256: '<evidence_pack.story_sha256>',
    decision: 'pass|revise（内部协议字段；对作者展示 visible_verdict）',
    visible_verdict: '故事层可进入表达清理|故事层可进入表达清理（有建议项）|故事层需先回炉',
    summary: '<基于读者卡与正文证据的全篇结论>',
    opening_assessment: { verdict: 'pass|concern|fail', evidence_quote: '<正文原句>', reason: '<是否场景化、是否信息过载>' },
    section_function_matrix: [{ section_index: 1, structural_role: '<本节职责>', function_verdict: 'pass|concern|fail', evidence_quote: '<正文原句>', note: '<篇幅与功能判断>' }],
    character_arc_matrix: [{ character: '<人物>', desire: '<想要什么>', independent_stake: '<不依附主角的自身利益或恐惧>', active_action: '<主动行动>', cost: '<代价>', relationship_effect: '<行动如何改变关系>', change: '<前后变化>', verdict: 'pass|concern|fail', evidence_quotes: ['<正文原句>'] }],
    identity_payoff_matrix: [{ identity_or_trait: '<职业/能力/缺陷/身份>', identity_type: '<职业|能力|缺陷|习惯|关系身份>', setup_quote: '<前文原句>', payoff_quote: '<后文原句>', ongoing_participation: '<是否持续改变行动与叙事>', verdict: 'pass|concern|fail' }],
    identity_not_applicable_reason: '<确实不适用时填写>',
    reveal_aftershock_matrix: [{ reveal_section_index: 1, revelation: '<关键揭示>', immediate_consequence: '<当场改变>', downstream_change: '<后续行动/关系/代价变化>', verdict: 'pass|concern|fail', evidence_quotes: ['<揭示原句>', '<后续原句>'] }],
    reveal_aftershock_not_applicable_reason: '<确实没有关键揭示时填写>',
    climax_ending_assessment: { verdict: 'pass|concern|fail', climax_quote: '<高潮原句>', ending_quote: '<结尾原句>', reason: '<高潮跑道、责任后果、标题兑现>' },
    findings: [{ code: '<稳定代码>', severity: 'S1|S2|S3|S4', scope: '<受影响小节/规划层>', evidence_quote: '<正文原句>', repair_direction: '<回写方向>' }],
  };
}

function invalidReviewResponse({ kind, findings, candidateRel, validationStateFile }) {
  const state = readJson(validationStateFile) || { schemaVersion: '1.0.0', invalid_counts: {} };
  state.invalid_counts = state.invalid_counts && typeof state.invalid_counts === 'object' ? state.invalid_counts : {};
  const count = Number(state.invalid_counts[kind] || 0) + 1;
  state.invalid_counts[kind] = count;
  state.updated_at = new Date().toISOString();
  atomicWriteJson(validationStateFile, state);
  if (count <= 1) {
    return {
      status: kind === 'reader_response' ? 'short_story_reader_response_invalid' : 'short_story_editorial_review_invalid',
      artifact: candidateRel,
      findings,
      retry_budget_remaining: 0,
      instruction: '只修订当前制品的缺失或证据不匹配字段一次，然后重跑同一 execution_command；不要重读 workflow 源码、重新生成另一张卡或修改正文。',
    };
  }
  return {
    status: 'short_story_review_manual_resolution_required',
    artifact: candidateRel,
    findings,
    retry_budget_exhausted: true,
    instruction: '同一审阅制品连续两次未通过合同，已停止自动重试。保留当前有效内容；由作者选择补缺项、接受部分报告或暂停，不得继续自动重读全文。',
  };
}

function reviewVerdict(decision, findings) {
  if (decision === 'revise') return { code: 'revision_required', label: '故事层需先回炉' };
  if ((findings || []).length) return { code: 'story_ready_with_advisory', label: '故事层可进入表达清理（有建议项）' };
  return { code: 'story_ready', label: '故事层可进入表达清理' };
}

function safeSegment(value) {
  return String(value || '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'default';
}

function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function hashFile(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') out.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-story-review-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-story-review-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n'); return 0; }

process.exitCode = main();
