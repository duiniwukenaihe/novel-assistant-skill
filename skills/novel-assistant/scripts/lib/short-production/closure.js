'use strict';

// Engine-neutral whole-story closure services for the V3 short workflow.
// This module returns contract-checked StageResult objects, writes only story
// artifacts and receipts, and never owns task transitions, pending actions,
// retry state, option numbers, or host rendering.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const {
  acceptTransaction,
  inspectChapter,
  prepareTransaction,
  rollbackPreparedTransaction,
} = require('../chapter-commit-store');
const { preservationCheck } = require('../short-deslop-preservation');
const { validateShortSectionAcceptanceProof } = require('../short-section-acceptance-proof');
const { resolveSectionLengthTarget } = require('../short-section-length-target');
const { SHORT_VOLUME, commitAcceptedSection } = require('../short-section-commit-store');
const {
  attachEvidenceRuntime,
  buildShortStoryEvidencePack,
  validateEditorialReviewCard,
  validateReaderResponseCard,
} = require('../short-story-editorial-review');
const { resolvePlannedSectionCount } = require('../short-workflow-state');
const { atomicWriteJson, atomicWriteText } = require('../workflow-state-store');
const {
  readShortProjectState,
  resolveShortProjectTitle,
  resolveShortStateRelative,
  shortStateFile,
} = require('../short-project-state');
const { stageResult } = require('../workflow-v3/contracts');

const ASSEMBLY_VOLUME = '短篇发布稿';
const RETRY_OPTIONS = Object.freeze([
  { action_id: 'inspect_current_state', label: '查看未通过项与现有依据' },
  { action_id: 'free_text', label: '说明希望怎样调整当前处理' },
  { action_id: 'retry_stage_contract', label: '按当前约束重新处理一次' },
]);

function assembleStory(context = {}) {
  const root = projectRoot(context);
  const task = taskSnapshot(context);
  const stageId = closureStage(task, 'assembly');
  const state = readShortProjectState(root) || {};
  const plan = plannedSections(root, state);
  if (plan.status !== 'locked') {
    return stageResult({
      kind: 'needs_author_choice', code: plan.status === 'conflict' ? 'short_section_plan_conflict' : 'short_section_plan_missing',
      stage_id: stageId, failure_family: 'assembly_plan',
      question: '全篇小节数还没有形成唯一结论，请先确认本次合稿范围。',
      options: [
        { action_id: 'confirm_section_plan', label: '重新确认全篇小节范围' },
        { action_id: 'inspect_current_state', label: '查看当前规划依据' },
        { action_id: 'free_text', label: '直接说明希望采用的范围' },
      ],
      plan_evidence: plan.candidates || [],
    });
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
      workflowId: String(task.workflow_id || ''),
      requireCommit: true,
      proof: {
        workflow_id: String(task.workflow_id || ''),
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
    sectionTexts.push(fs.readFileSync(safeProjectFile(root, proof.canonical_path), 'utf8').trim());
  }
  const outsidePlan = [...accepted.keys()]
    .filter((value) => Number.isInteger(value) && value > plan.count)
    .sort((a, b) => a - b);
  if (missing.length || invalid.length || outsidePlan.length) {
    const resolvedAction = resolvedAssemblyAction(task);
    const currentProseDrift = !missing.length && !outsidePlan.length && invalid.length > 0
      && invalid.every((finding) => String(finding.reason || '') === 'short_section_canonical_sha256_mismatch');
    if (currentProseDrift && ['revalidate_current_sections', 'repair_missing_sections'].includes(resolvedAction)) {
      const staged = stageCurrentSectionsForRevalidation(root, accepted, invalid);
      if (staged.status !== 'ready') {
        return retryAwareFailure(task, stageId, {
          family: 'assembly_revalidation_staging', code: staged.code,
          findings: staged.findings,
          instruction: '保留现有正式正文；先恢复缺失的当前小节文件，再重新建立复检队列。',
        });
      }
      return stageResult({
        kind: 'completed', code: 'short_story_assembly_revalidation_started',
        stage_id: stageId, next_stage: 'machine_gate',
        section_index: Number(invalid[0].section_index),
        missing_sections: [], invalid_sections: invalid,
        staged_candidates: staged.candidates,
      });
    }
    const legacyMigrationAvailable = !missing.length && !outsidePlan.length && invalid.length > 0
      && invalid.every((finding) => {
        const item = accepted.get(Number(finding.section_index));
        const canonical = `正文/第${pad(finding.section_index)}节.md`;
        return item && (String(item.canonical_path || '') !== canonical || !String(item.section_commit_id || ''));
      });
    const options = [
      legacyMigrationAvailable
        ? { action_id: 'migrate_legacy_assets', label: '迁移旧项目的小节事实源' }
        : currentProseDrift
          ? { action_id: 'revalidate_current_sections', label: '保留现稿并逐节重新验收' }
          : { action_id: 'repair_missing_sections', label: '补齐或重新验收受影响小节' },
      { action_id: 'inspect_current_state', label: '查看缺失、失效与计划外小节' },
      { action_id: 'free_text', label: '说明希望保留或调整的范围' },
    ];
    return stageResult({
      kind: 'needs_author_choice', code: 'short_story_assembly_integrity_required',
      stage_id: stageId, failure_family: 'assembly_integrity',
      question: '全篇还不能安全合稿，请先处理小节完整性问题。', options,
      planned_sections: plan.count, missing_sections: missing,
      invalid_sections: invalid, outside_plan_sections: outsidePlan,
      legacy_migration_available: legacyMigrationAvailable,
      ...(legacyMigrationAvailable ? {
        migration_command: `node scripts/short-section-artifact-migrate.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(String(task.workflow_id || ''))} --confirm --json`,
      } : {}),
    });
  }

  const assembledText = `${sectionTexts.join('\n\n')}\n`;
  const artifactRoot = closureArtifactRoot(task, 'assembly');
  const stagedRel = `${artifactRoot}/正文.md`;
  const manifestRel = `${artifactRoot}/manifest.json`;
  atomicWriteText(safeProjectFile(root, stagedRel), assembledText);
  atomicWriteJson(safeProjectFile(root, manifestRel), {
    schemaVersion: '1.0.0', workflow_id: String(task.workflow_id || ''),
    volume: ASSEMBLY_VOLUME, chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: 'short_story_release_body', required: true, staged: stagedRel, target: '正文.md' }],
    facts: [],
  });
  let commit;
  let preparedTransactionId = '';
  try {
    commit = matchingWholeStoryCommit(root, task.workflow_id, assembledText);
    if (!commit) {
      const prepared = prepareTransaction(root, manifestRel);
      preparedTransactionId = String(prepared.transaction_id || '');
      commit = acceptTransaction(root, preparedTransactionId);
    }
  } catch (error) {
    if (preparedTransactionId) {
      try {
        rollbackPreparedTransaction(root, preparedTransactionId,
          `assembly accept failed: ${String(error.status || error.code || error.message || error)}`);
      } catch (_) {
        // Preserve the original commit error; a later recovery may reconcile the transaction.
      }
    }
    return retryAwareFailure(task, stageId, {
      family: 'assembly_commit', code: String(error.status || 'short_story_assembly_commit_blocked'),
      detail: String(error.message || error), instruction: '已采用的小节仍然保留；只恢复本次合稿事务，不要重写正文。',
    });
  }
  const storyFile = safeProjectFile(root, '正文.md');
  const canonicalHash = hashFile(storyFile);
  const receiptRel = writeClosureReceipt(root, task, 'assembly', {
    schema_version: '1.0.0', workflow_id: String(task.workflow_id || ''),
    stage_attempt_id: stageAttempt(task), planned_sections: plan.count,
    assembled_sections: plan.count, canonical_path: '正文.md', canonical_sha256: canonicalHash,
    assembly_commit_id: String(commit.commit_id || ''),
  });
  return stageResult({
    kind: 'completed', code: 'short_story_assembled', stage_id: stageId,
    next_stage: 'editorial_review',
    planned_sections: plan.count, assembled_sections: plan.count,
    canonical_path: '正文.md', canonical_sha256: canonicalHash,
    assembly_commit_id: String(commit.commit_id || ''), receipt_path: receiptRel,
  });
}

function resolvedAssemblyAction(task) {
  const pending = (task || {}).pending_action;
  if (!pending || String(pending.status || '') !== 'resolved') return '';
  return String(((pending.selection || {}).action_id) || '');
}

function stageCurrentSectionsForRevalidation(root, accepted, invalid) {
  const candidates = [];
  const findings = [];
  for (const finding of invalid) {
    const sectionIndex = Number(finding.section_index || 0);
    const item = accepted.get(sectionIndex) || {};
    const sourceRel = String(item.canonical_path || `正文/第${pad(sectionIndex)}节.md`);
    const sourceFile = safeProjectFile(root, sourceRel);
    if (!fs.existsSync(sourceFile) || !fs.statSync(sourceFile).isFile()) {
      findings.push({ section_index: sectionIndex, code: 'short_section_current_source_missing', source_path: sourceRel });
      continue;
    }
    const candidateRel = `草稿_第${pad(sectionIndex)}节_候选.md`;
    atomicWriteText(safeProjectFile(root, candidateRel), fs.readFileSync(sourceFile, 'utf8'));
    candidates.push({ section_index: sectionIndex, source_path: sourceRel, candidate_path: candidateRel });
  }
  return findings.length
    ? { status: 'blocked', code: 'short_section_current_source_missing', findings, candidates }
    : { status: 'ready', candidates };
}

function finalizeEditorialReview(context = {}) {
  const root = projectRoot(context);
  const task = taskSnapshot(context);
  const stageId = closureStage(task, 'editorial_review');
  const storyFile = safeProjectFile(root, '正文.md');
  const pack = attachEvidenceRuntime(buildShortStoryEvidencePack(root, {
    workflowId: String(task.workflow_id || ''), storyPath: '正文.md',
  }), storyFile);
  if (pack.status !== 'ok') {
    return retryAwareFailure(task, stageId, {
      family: 'editorial_evidence', code: String(pack.status || 'short_story_evidence_unavailable'),
      findings: pack.findings || [], instruction: '先恢复当前正式合稿和逐节依据，再进行全篇审阅。',
    });
  }
  const artifactRoot = closureArtifactRoot(task, 'editorial-review');
  const evidenceRel = `${artifactRoot}/evidence-pack.json`;
  const readerCandidateRel = String(context.readerResponsePath || `${artifactRoot}/reader-response.json`);
  const reviewCandidateRel = String(context.reviewCardPath || `${artifactRoot}/editorial-review.json`);
  const acceptedReaderRel = `${artifactRoot}/accepted-reader-response.json`;
  const acceptedReviewRel = `${artifactRoot}/accepted-editorial-review.json`;
  atomicWriteJson(safeProjectFile(root, evidenceRel), pack);

  const reader = readJson(safeProjectFile(root, readerCandidateRel));
  if (!reader) {
    return stageResult({
      kind: 'blocked', code: 'short_story_reader_response_required', stage_id: stageId,
      evidence_pack: evidenceRel, reader_response_card: readerCandidateRel,
      review_card: reviewCandidateRel,
      instruction: '先完成一次只读盲读并写入读者反应卡，不要修改正文。',
    });
  }
  const readerValidation = validateReaderResponseCard(reader, pack);
  if (readerValidation.status !== 'valid') {
    return retryAwareFailure(task, stageId, {
      family: 'reader_response', code: 'short_story_reader_response_invalid',
      findings: readerValidation.findings, artifact: readerCandidateRel,
      instruction: '只补齐读者反应卡中缺失或证据不匹配的字段一次。',
    });
  }
  atomicWriteJson(safeProjectFile(root, acceptedReaderRel), reader);

  const card = readJson(safeProjectFile(root, reviewCandidateRel));
  if (!card) {
    return stageResult({
      kind: 'blocked', code: 'short_story_editorial_review_required', stage_id: stageId,
      evidence_pack: evidenceRel, reader_response_card: acceptedReaderRel,
      review_card: reviewCandidateRel,
      instruction: '基于正文、证据包和已接受的读者反应卡完成编辑裁决，不要修改正文。',
    });
  }
  const validation = validateEditorialReviewCard(card, pack, { readerResponse: reader });
  if (validation.status !== 'valid') {
    return retryAwareFailure(task, stageId, {
      family: 'editorial_review', code: 'short_story_editorial_review_invalid',
      findings: validation.findings, artifact: reviewCandidateRel,
      instruction: '只修订编辑裁决卡中缺失或证据不匹配的字段一次。',
    });
  }
  if (String(card.decision || '') === 'pass') {
    const lengthFindings = collectUnconfirmedLengthDecisions(root);
    if (lengthFindings.length) {
      const state = readShortProjectState(root) || {};
      const accepted = new Map((Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
        .map((item) => [Number((item || {}).section_index), item]));
      const invalid = lengthFindings.map((item) => ({
        section_index: Number(item.section_index || 0),
        reason: String(item.code || 'section_length_repair_required'),
      }));
      const staged = stageCurrentSectionsForRevalidation(root, accepted, invalid);
      if (staged.status !== 'ready') {
        return retryAwareFailure(task, stageId, {
          family: 'editorial_length_staging', code: staged.code,
          findings: staged.findings,
          instruction: '保留现有正式正文；先恢复明显欠写小节的当前文件，再进入自动回炉。',
        });
      }
      return stageResult({
        kind: 'completed', code: 'short_story_length_revision_required',
        stage_id: stageId, decision: 'revise', next_stage: 'machine_gate',
        section_index: Number(lengthFindings[0].section_index),
        length_findings: lengthFindings, findings: lengthFindings,
        staged_candidates: staged.candidates,
      });
    }
  }
  atomicWriteJson(safeProjectFile(root, acceptedReviewRel), card);
  const decision = String(card.decision || '');
  const findings = Array.isArray(card.findings) ? card.findings : [];
  const reviewHash = hashFile(safeProjectFile(root, acceptedReviewRel));
  const receiptRel = writeClosureReceipt(root, task, 'editorial-review', {
    schema_version: '1.0.0', workflow_id: String(task.workflow_id || ''),
    stage_attempt_id: stageAttempt(task), decision, story_path: '正文.md',
    story_sha256: pack.story_sha256, evidence_pack_path: evidenceRel,
    reader_response_path: acceptedReaderRel, review_card_path: acceptedReviewRel,
    review_card_sha256: reviewHash, findings,
  });
  return stageResult({
    kind: 'completed', code: decision === 'pass' ? 'short_story_editorial_passed' : 'short_story_editorial_revision_required',
    stage_id: stageId, decision, story_sha256: pack.story_sha256,
    reader_response_path: acceptedReaderRel, review_card_path: acceptedReviewRel,
    review_card_sha256: reviewHash, receipt_path: receiptRel,
    findings,
    section_indices: (Array.isArray(pack.section_metrics) ? pack.section_metrics : [])
      .map(item => Number((item || {}).section_index))
      .filter(index => Number.isInteger(index) && index > 0),
    feedback: decision === 'revise' ? { items: findings } : { items: [] },
    next_stage: decision === 'pass' ? 'deslop' : 'planning_confirmation',
  });
}

function finalizeDeslop(context = {}) {
  const root = projectRoot(context);
  const task = taskSnapshot(context);
  const stageId = closureStage(task, 'deslop');
  const stagedRel = String(context.stagedPath || ((task.stage_execution || {}).deslop_target) || '');
  const stagedFile = safeProjectFile(root, stagedRel);
  if (!stagedRel || !fs.existsSync(stagedFile)) {
    return stageResult({
      kind: 'blocked', code: 'short_deslop_staged_draft_missing', stage_id: stageId,
      staged_target: stagedRel, instruction: '先生成全篇表达精修暂存稿，不要直接修改正式合稿。',
    });
  }
  const sourceFile = safeProjectFile(root, '正文.md');
  if (!fs.existsSync(sourceFile)) {
    return stageResult({
      kind: 'blocked', code: 'short_deslop_source_missing', stage_id: stageId,
      instruction: '正式合稿缺失；先恢复全篇组装结果。',
    });
  }
  const sourceText = fs.readFileSync(sourceFile, 'utf8');
  const text = fs.readFileSync(stagedFile, 'utf8');
  const state = readShortProjectState(root) || {};
  const plan = plannedSections(root, state);
  const headings = sectionIndexes(text);
  const expected = plan.status === 'locked' ? sequence(plan.count) : [];
  if (plan.status !== 'locked' || !sameSequence(headings, expected)) {
    return retryAwareFailure(task, stageId, {
      family: 'deslop_section_identity', code: 'short_deslop_section_identity_changed',
      planned_sections: plan.count || 0, actual_sections: headings,
      instruction: '表达精修改变了节数或节序；只恢复结构，不改剧情方向。',
    });
  }
  const pollution = runJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
  const ai = runJson(root, 'check-ai-patterns.js', ['--check', '--json', '--fail-on=blocking', stagedFile]);
  const pollutionFindings = Array.isArray(pollution.findings) ? pollution.findings : [];
  const aiFindings = (Array.isArray(ai.findings) ? ai.findings : [])
    .filter((item) => String(item.severity || '') === 'blocking');
  if (pollutionFindings.length || aiFindings.length) {
    return retryAwareFailure(task, stageId, {
      family: pollutionFindings.length ? 'deslop_pollution' : 'deslop_ai',
      code: 'short_deslop_revision_required', findings: [...pollutionFindings, ...aiFindings].slice(0, 24),
      instruction: '只修复当前暂存稿中的阻断项，不扩写新剧情。',
    });
  }
  const preservation = preservationCheck(sourceText, text, {
    exceptionReason: String(context.preservationException || ''),
  });
  if (preservation.blocking) {
    return retryAwareFailure(task, stageId, {
      family: 'deslop_preservation', code: 'short_deslop_preservation_revision_required',
      findings: preservation.findings, preservation,
      instruction: preservation.repair_principle,
    });
  }
  const reviewReceipt = readLatestReceipt(root, task, 'editorial-review');
  const sourceHash = hashFile(sourceFile);
  if (!reviewReceipt || String(reviewReceipt.decision || '') !== 'pass'
      || String(reviewReceipt.story_sha256 || '') !== sourceHash) {
    return retryAwareFailure(task, stageId, {
      family: 'deslop_review_binding', code: 'short_deslop_editorial_review_stale',
      reviewed: String((reviewReceipt || {}).story_sha256 || ''), source: sourceHash,
      instruction: '当前正式合稿与审阅回执不一致；先重新完成全篇审阅。',
    });
  }

  const acceptedByIndex = new Map((Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
    .map((item) => [Number((item || {}).section_index), { ...(item || {}) }]));
  const acceptedDigests = [];
  for (const section of splitSections(text)) {
    let commit;
    try {
      commit = commitAcceptedSection(root, {
        task, sectionIndex: section.section_index, title: section.title, text: section.body,
        metadata: {}, projectTitle: resolveShortProjectTitle(state, path.basename(root)),
      });
    } catch (error) {
      return retryAwareFailure(task, stageId, {
        family: 'deslop_section_commit', code: String(error.status || 'short_deslop_section_commit_blocked'),
        section_index: section.section_index, detail: String(error.message || error),
        instruction: '已完成的小节提交可复用；只恢复当前提交，不重新精修全篇。',
      });
    }
    const anchorRel = resolveShortStateRelative(root, `section-${pad(section.section_index)}-anchor.json`, { forWrite: true });
    const anchorFile = safeProjectFile(root, anchorRel);
    const anchor = readJson(anchorFile) || {};
    const acceptedCommit = (inspectChapter(root, SHORT_VOLUME, section.section_index) || {}).latest_commit || {};
    const expressionRevisionAt = String(acceptedCommit.accepted_at || anchor.expression_revision_at || '');
    const nextAnchor = {
      ...anchor, workflow_id: String(task.workflow_id || ''), section_index: section.section_index,
      section_title: section.title, status: 'accepted', canonical_path: commit.canonical_path,
      canonical_sha256: commit.canonical_sha256, section_commit_id: commit.commit_id,
      expression_revision_at: expressionRevisionAt,
    };
    if (!sameJson(anchor, nextAnchor)) atomicWriteJson(anchorFile, nextAnchor);
    const previous = acceptedByIndex.get(section.section_index) || { section_index: section.section_index };
    acceptedByIndex.set(section.section_index, {
      ...previous, title: section.title, anchor_path: anchorRel, canonical_path: commit.canonical_path,
      sha256: commit.canonical_sha256, section_commit_id: commit.commit_id,
      length_chars: countCjk(section.body),
    });
    acceptedDigests.push({
      section_index: section.section_index, canonical_sha256: commit.canonical_sha256,
      section_commit_id: commit.commit_id,
    });
  }
  const artifactRoot = closureArtifactRoot(task, 'deslop');
  const manifestRel = `${artifactRoot}/manifest.json`;
  atomicWriteJson(safeProjectFile(root, manifestRel), {
    schemaVersion: '1.0.0', workflow_id: String(task.workflow_id || ''),
    volume: ASSEMBLY_VOLUME, chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: 'short_story_deslopped_body', required: true, staged: stagedRel, target: '正文.md' }],
    facts: [],
  });
  let wholeCommit;
  try {
    wholeCommit = matchingWholeStoryCommit(root, task.workflow_id, text)
      || acceptTransaction(root, prepareTransaction(root, manifestRel).transaction_id);
  } catch (error) {
    return retryAwareFailure(task, stageId, {
      family: 'deslop_whole_commit', code: String(error.status || 'short_deslop_commit_blocked'),
      detail: String(error.message || error), instruction: '暂存稿仍然保留；只恢复正式合稿提交。',
    });
  }
  const canonicalHash = hashFile(sourceFile);
  const latestWholeCommit = (inspectChapter(root, ASSEMBLY_VOLUME, 1) || {}).latest_commit || {};
  const acceptedSections = [...acceptedByIndex.values()].sort((a, b) => Number(a.section_index) - Number(b.section_index));
  const sameExpressionRevision = String(state.expression_revision_sha256 || '') === canonicalHash;
  const nextState = {
    ...state, accepted_sections: acceptedSections,
    expression_revision_at: sameExpressionRevision
      ? String(state.expression_revision_at || '')
      : String(latestWholeCommit.accepted_at || ''),
    expression_revision_sha256: canonicalHash,
  };
  if (!sameJson(state, nextState)) atomicWriteJson(shortStateFile(root, 'project-state.json', { forWrite: true }), nextState);
  const receiptRel = writeClosureReceipt(root, task, 'deslop', {
    schema_version: '1.0.0', workflow_id: String(task.workflow_id || ''),
    stage_attempt_id: stageAttempt(task), canonical_path: '正文.md',
    source_canonical_sha256: sourceHash, canonical_sha256: canonicalHash,
    commit_id: String(wholeCommit.commit_id || ''), preservation_result: preservation,
    accepted_section_digests: acceptedDigests,
  });
  return stageResult({
    kind: 'completed', code: 'short_deslop_completed', stage_id: stageId,
    canonical_path: '正文.md', source_canonical_sha256: sourceHash,
    canonical_sha256: canonicalHash, deslop_commit_id: String(wholeCommit.commit_id || ''),
    preservation_result: preservation, accepted_section_digests: acceptedDigests,
    receipt_path: receiptRel,
  });
}

function runFinalCheck(context = {}) {
  const root = projectRoot(context);
  const task = taskSnapshot(context);
  const stageId = closureStage(task, 'final_check');
  const storyFile = safeProjectFile(root, '正文.md');
  if (!fs.existsSync(storyFile)) {
    return stageResult({
      kind: 'blocked', code: 'short_final_prose_missing', stage_id: stageId,
      instruction: '正式合稿缺失；先恢复全篇组装。',
    });
  }
  const text = fs.readFileSync(storyFile, 'utf8');
  const state = readShortProjectState(root) || {};
  const plan = plannedSections(root, state);
  const headings = sectionIndexes(text);
  const review = readLatestReceipt(root, task, 'editorial-review');
  const deslop = readLatestReceipt(root, task, 'deslop');
  const actualHash = hashText(text);
  const findings = [];
  if (plan.status !== 'locked') findings.push({ code: 'planned_sections_not_locked', message: '全篇小节数尚未锁定。' });
  else if (!sameSequence(headings, sequence(plan.count))) findings.push({ code: 'section_sequence_mismatch', expected: sequence(plan.count), actual: headings });
  if (!deslop || String(deslop.canonical_sha256 || '') !== actualHash) findings.push({ code: 'deslop_receipt_hash_mismatch', expected: String((deslop || {}).canonical_sha256 || ''), actual: actualHash });
  if (!review || String(review.decision || '') !== 'pass') findings.push({ code: 'full_story_editorial_review_not_passed', decision: String((review || {}).decision || '') });
  if (!deslop || !review || String(deslop.source_canonical_sha256 || '') !== String(review.story_sha256 || '')) findings.push({ code: 'full_story_editorial_review_stale', reviewed: String((review || {}).story_sha256 || ''), deslop_source: String((deslop || {}).source_canonical_sha256 || '') });
  const preservation = (deslop || {}).preservation_result || {};
  if (!['pass', 'explicit_exception'].includes(String(preservation.status || ''))) findings.push({ code: 'short_deslop_preservation_missing', status: String(preservation.status || '') });
  if (plan.status === 'locked') {
    findings.push(...acceptedStoryIntegrityFindings(root, task, state, plan.count, deslop, text));
  }
  if (findings.length) {
    return retryAwareFailure(task, stageId, {
      family: 'final_check_receipts', code: 'short_final_check_blocked', findings,
      instruction: '按未通过项恢复正式稿或对应回执，不要重新写全篇。',
    });
  }
  const lengthAdvisories = collectLengthAdvisories(root);
  const receiptRel = writeClosureReceipt(root, task, 'final-check', {
    schema_version: '1.0.0', workflow_id: String(task.workflow_id || ''),
    stage_attempt_id: stageAttempt(task), planned_sections: plan.count,
    assembled_sections: headings.length, canonical_sha256: actualHash,
    editorial_review_sha256: review.story_sha256,
    deslop_preservation_status: preservation.status,
    length_advisories: lengthAdvisories,
  });
  return stageResult({
    kind: 'completed', code: 'short_final_check_passed', stage_id: stageId,
    planned_sections: plan.count, assembled_sections: headings.length,
    canonical_path: '正文.md', canonical_sha256: actualHash,
    editorial_decision: review.decision, deslop_preservation_status: preservation.status,
    length_advisories: lengthAdvisories, receipt_path: receiptRel,
    completion_event: {
      event_type: 'story_completed', workflow_id: String(task.workflow_id || ''),
      project_id: String(state.project_id || ''), project_title: resolveShortProjectTitle(state, path.basename(root)),
      artifact_path: '正文.md', artifact_digest: `sha256:${actualHash}`,
      summary: `短篇已完成最终检查，共 ${plan.count} 节。`, tags: ['short_write', 'completed'],
    },
  });
}

function acceptedStoryIntegrityFindings(root, task, state, plannedCount, deslopReceipt, storyText) {
  const findings = [];
  const accepted = new Map((Array.isArray(state.accepted_sections) ? state.accepted_sections : [])
    .map((item) => [Number((item || {}).section_index), item]));
  const receiptDigests = new Map((Array.isArray((deslopReceipt || {}).accepted_section_digests)
    ? deslopReceipt.accepted_section_digests : [])
    .map((item) => [Number((item || {}).section_index), item]));
  const canonicalSections = [];
  for (let sectionIndex = 1; sectionIndex <= plannedCount; sectionIndex += 1) {
    const item = accepted.get(sectionIndex);
    if (!item) {
      findings.push({ code: 'accepted_section_missing', section_index: sectionIndex });
      continue;
    }
    const proof = validateShortSectionAcceptanceProof({
      projectRoot: root,
      workflowId: String(task.workflow_id || ''),
      requireCommit: true,
      proof: {
        workflow_id: String(task.workflow_id || ''), section_index: sectionIndex,
        anchor_path: item.anchor_path, canonical_path: item.canonical_path,
        canonical_sha256: item.sha256, section_commit_id: item.section_commit_id,
      },
    });
    if (proof.status !== 'accepted') {
      findings.push({
        code: 'accepted_section_proof_invalid', section_index: sectionIndex,
        reason: proof.code || 'invalid_acceptance',
      });
      continue;
    }
    const receipt = receiptDigests.get(sectionIndex);
    if (!receipt
        || String(receipt.canonical_sha256 || '') !== String(proof.canonical_sha256 || '')
        || String(receipt.section_commit_id || '') !== String(proof.section_commit_id || '')) {
      findings.push({ code: 'accepted_section_deslop_receipt_mismatch', section_index: sectionIndex });
      continue;
    }
    canonicalSections.push(fs.readFileSync(safeProjectFile(root, proof.canonical_path), 'utf8').trim());
  }
  const outsidePlan = [...accepted.keys()].filter((value) => Number.isInteger(value) && value > plannedCount);
  if (outsidePlan.length) findings.push({ code: 'accepted_section_outside_plan', section_indexes: outsidePlan.sort((a, b) => a - b) });
  if (!findings.length && canonicalSections.join('\n\n').trim() !== String(storyText || '').trim()) {
    findings.push({ code: 'accepted_sections_story_mismatch' });
  }
  return findings;
}

function retryAwareFailure(task, stageId, detail = {}) {
  const family = String(detail.family || detail.code || 'closure_failure');
  const previous = task.retry_state && typeof task.retry_state === 'object' ? task.retry_state : null;
  const exhausted = Boolean(previous)
    && String(previous.stage_id || '') === String(stageId || '')
    && String(previous.failure_family || '') === family
    && Number(previous.count || 0) >= 1;
  if (!exhausted) {
    const { family: ignored, ...rest } = detail;
    return stageResult({
      kind: 'retryable_internal', stage_id: stageId, failure_family: family, ...rest,
    });
  }
  const { family: ignored, ...rest } = detail;
  return stageResult({
    kind: 'needs_author_choice', stage_id: stageId, failure_family: family,
    question: '当前阶段连续两次遇到同一问题，请决定怎样继续，避免重复改写。',
    options: RETRY_OPTIONS, ...rest,
  });
}

function projectRoot(context) {
  const root = path.resolve(String(context.projectRoot || ''));
  if (!root || !fs.existsSync(root) || !fs.statSync(root).isDirectory()) throw new Error('project_root_missing');
  return root;
}

function taskSnapshot(context) {
  const task = context.task && typeof context.task === 'object' ? context.task : null;
  if (!task || !String(task.workflow_id || '') || !String(task.task_dir || '')) throw new Error('task_snapshot_missing');
  return task;
}

function closureStage(task, expected) {
  const stage = String((task || {}).current_stage || '');
  if (stage !== expected) throw new Error(`stage_action_not_applicable:${expected}:${stage || 'missing'}`);
  return stage;
}

function closureArtifactRoot(task, name) {
  return `${String(task.task_dir || '')}/artifacts/closure/${name}/attempts/${safeSegment(stageAttempt(task))}`;
}

function readLatestReceipt(root, task, name) {
  const latestRel = `${String(task.task_dir || '')}/artifacts/closure/${name}/latest.json`;
  const latest = readJson(safeProjectFile(root, latestRel));
  if (!latest || String(latest.workflow_id || '') !== String(task.workflow_id || '')) return null;
  let receiptFile;
  try { receiptFile = safeProjectFile(root, String(latest.receipt_path || '')); } catch (_) { return null; }
  if (!fs.existsSync(receiptFile) || hashFile(receiptFile) !== String(latest.receipt_sha256 || '')) return null;
  const receipt = readJson(receiptFile);
  return receipt && String(receipt.workflow_id || '') === String(task.workflow_id || '') ? receipt : null;
}

function writeClosureReceipt(root, task, name, receipt) {
  const receiptRel = `${closureArtifactRoot(task, name)}/receipt.json`;
  const receiptFile = safeProjectFile(root, receiptRel);
  atomicWriteJson(receiptFile, receipt);
  atomicWriteJson(safeProjectFile(root, `${String(task.task_dir || '')}/artifacts/closure/${name}/latest.json`), {
    schema_version: '1.0.0', workflow_id: String(task.workflow_id || ''),
    stage_attempt_id: stageAttempt(task), receipt_path: receiptRel,
    receipt_sha256: hashFile(receiptFile),
  });
  return receiptRel;
}

function plannedSections(root, state) {
  return resolvePlannedSectionCount({
    projectState: state || {},
    titleLock: readJson(shortStateFile(root, 'section-title-lock.json')) || {},
    outlineText: readText(safeProjectFile(root, '小节大纲.md')),
  });
}

function matchingWholeStoryCommit(root, workflowId, text) {
  const commit = (inspectChapter(root, ASSEMBLY_VOLUME, 1) || {}).latest_commit;
  const hash = hashText(text);
  if (!commit || String(commit.workflow_id || '') !== String(workflowId || '')) return null;
  const artifact = (commit.artifacts || []).find((item) => String(item.target || '') === '正文.md');
  const storyFile = safeProjectFile(root, '正文.md');
  return artifact && normalizeHash(artifact.after_hash || artifact.content_hash) === hash
    && fs.existsSync(storyFile) && hashFile(storyFile) === hash ? commit : null;
}

function splitSections(text) {
  const source = String(text || '');
  const matches = [...source.matchAll(/^##\s+第\s*0*(\d+)\s*节(?:\s+([^\n]+))?\s*$/gmu)];
  return matches.map((match, index) => ({
    section_index: Number(match[1]), title: String(match[2] || '').trim() || `第${Number(match[1])}节`,
    body: source.slice(match.index + match[0].length, matches[index + 1] ? matches[index + 1].index : source.length).trim(),
  }));
}

function sectionIndexes(text) {
  return [...String(text || '').matchAll(/^##\s+第\s*0*(\d+)\s*节(?:\s+[^\n]*)?$/gmu)].map((match) => Number(match[1]));
}

function collectLengthAdvisories(root) {
  const dir = path.dirname(shortStateFile(root, 'project-state.json'));
  let names = [];
  try { names = fs.readdirSync(dir); } catch (_) { return []; }
  return names.filter((name) => /^section-\d{3}-anchor\.json$/u.test(name))
    .map((name) => readJson(path.join(dir, name))).filter(Boolean)
    .map((anchor) => ({ section_index: Number(anchor.section_index || 0), length_policy: (((anchor || {}).quality_result || {}).length_policy || {}) }))
    .filter((item) => [
      'outside_story_band_deferred',
      'under_target_review_completeness',
      'over_target_review_pacing',
      'under_hard_floor',
    ].includes(String(item.length_policy.verdict || '')))
    .map((item) => ({
      debt_type: 'section_length_variance', severity: 'advisory', scope: `第${item.section_index}节`,
      observed_chars: Number(item.length_policy.observed_chars || 0),
      baseline_chars: Number(item.length_policy.baseline_chars || 0),
      recommended_fix: '结合本节剧情功能选择补写、压缩或保留；不要机械补字。',
    }));
}

function collectUnconfirmedLengthDecisions(root) {
  const dir = path.dirname(shortStateFile(root, 'project-state.json'));
  const projectState = readShortProjectState(root) || {};
  let names = [];
  try { names = fs.readdirSync(dir); } catch (_) { return []; }
  return names.filter((name) => /^section-\d{3}-anchor\.json$/u.test(name))
    .map((name) => ({ name, anchor: readJson(path.join(dir, name)) }))
    .filter((item) => item.anchor)
    .map((item) => {
      const policy = ((((item.anchor || {}).quality_result || {}).length_policy) || {});
      const observed = Number(policy.observed_chars || 0);
      const sectionIndex = Number(item.anchor.section_index || 0);
      const target = resolveSectionLengthTarget(root, projectState, sectionIndex);
      const baseline = Number(target.chars || 0);
      const hardFloor = Number((target.range || {}).min || Math.max(1, baseline - Math.ceil(baseline * 0.10)));
      const hardCeiling = Number((target.range || {}).max || baseline + Math.ceil(baseline * 0.20));
      if (!observed || !baseline || target.enforcement !== 'hard'
          || (observed >= hardFloor && observed <= hardCeiling)
          || String(policy.verdict || '') === 'explicit_story_exception') {
        return null;
      }
      const under = observed < hardFloor;
      const gapPercent = Math.abs(observed - baseline) / baseline * 100;
      return {
        code: under ? 'section_length_under_target' : 'section_length_over_target',
        severity: 'S2',
        scope: `第${sectionIndex}节`,
        section_index: sectionIndex,
        observed_chars: observed,
        target_chars: baseline,
        target_source: target.source,
        target_evidence_path: String(target.evidence_path || ''),
        hard_floor: hardFloor,
        hard_ceiling: hardCeiling,
        gap_percent: Number(gapPercent.toFixed(1)),
        anchor_name: item.name,
        message: `第${sectionIndex}节目标${baseline}字，实际${observed}字，${under ? '少' : '多'}${Math.abs(observed - baseline)}字（缺口${gapPercent.toFixed(1)}%）。`,
        repair_direction: under
          ? '自动回炉本节，补足真实事件、冲突、选择或钩子；不得让作者确认欠写。'
          : '自动回炉本节，删除重复和无功能段落；承担项过载时回到规划拆解。',
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.section_index - right.section_index);
}

function runJson(root, script, argv) {
  const run = spawnSync(process.execPath, [path.join(__dirname, '..', '..', script), ...argv], {
    cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
  });
  try { return JSON.parse(String(run.stdout || '').trim()); } catch (_) {
    return { status: 'checker_failed', findings: [{ type: script, message: String(run.stderr || '').trim().slice(0, 500) }] };
  }
}

function safeProjectFile(root, rel) {
  const raw = String(rel || '').trim();
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/u).includes('..')) throw new Error(`unsafe_project_path:${rel}`);
  const file = path.resolve(root, raw);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error(`unsafe_project_path:${rel}`);
  return file;
}

function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function sameJson(left, right) { return JSON.stringify(left) === JSON.stringify(right); }
function hashText(value) { return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex'); }
function hashFile(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function normalizeHash(value) { return String(value || '').replace(/^sha256:/u, ''); }
function stageAttempt(task) { return String(((task || {}).stage_execution || {}).stage_attempt_id || 'legacy-attempt'); }
function safeSegment(value) { return String(value || '').replace(/[^A-Za-z0-9._-]+/gu, '-').replace(/^-+|-+$/gu, '') || 'default'; }
function pad(value) { return String(Number(value || 0)).padStart(3, '0'); }
function sequence(count) { return Array.from({ length: Number(count || 0) }, (_, index) => index + 1); }
function sameSequence(actual, expected) { return actual.length === expected.length && actual.every((value, index) => value === expected[index]); }
function countCjk(value) { return (String(value || '').match(/[\u3400-\u9fff]/gu) || []).length; }

module.exports = {
  assembleStory,
  finalizeEditorialReview,
  finalizeDeslop,
  runFinalCheck,
};
