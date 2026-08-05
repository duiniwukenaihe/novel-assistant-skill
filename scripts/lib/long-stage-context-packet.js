'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { compactToTokens, estimateTokens } = require('./context-budget');
const { checkLongCharacterContract } = require('./long-character-contract');
const { evaluateLongChapterLength } = require('./long-chapter-length-contract');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');
const {
  formatLongChapterDisplay,
  validateLongChapterTargetV2,
} = require('./long-chapter-target');

const LONG_STAGES = new Set(['chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit']);
const LONG_OUTLINE_REVIEW_STAGES = new Set(['detail_outline_review']);
const LONG_OUTLINE_REVISION_STAGES = new Set(['stage_detail_outline']);
const DEFAULT_TOKEN_BUDGET = 6000;

function activeChapterTarget(task) {
  const frozen = ((task || {}).stage_execution || {}).chapter_target;
  if (frozen && frozen.outline_path) return frozen;
  return null;
}

function buildLongStageContextPacket({ projectRoot, task, stage, options = {} } = {}) {
  const root = path.resolve(projectRoot || '');
  const stageId = String(stage || (task || {}).current_stage || '');
  if (!root || !fs.existsSync(root) || String((task || {}).workflow_type || '') !== 'long_write'
      || (!LONG_STAGES.has(stageId) && !LONG_OUTLINE_REVIEW_STAGES.has(stageId) && !LONG_OUTLINE_REVISION_STAGES.has(stageId))) {
    return { status: 'not_applicable', reason: 'not_long_chapter_stage' };
  }
  if (LONG_OUTLINE_REVIEW_STAGES.has(stageId)) {
    return buildDetailOutlineReviewContextPacket({ root, task, stageId, options });
  }
  if (LONG_OUTLINE_REVISION_STAGES.has(stageId)) {
    return buildDetailOutlineRevisionContextPacket({ root, task, stageId, options });
  }
  const characterContract = checkLongCharacterContract(root);
  if (characterContract.status !== 'pass') {
    return {
      status: 'blocked_long_character_contract_upgrade_required',
      blocking: true,
      reason: '人物设定尚不足以支撑稳定的章节写作；请先补全人物目标、缺陷、能力边界、压力角色和关系债。',
      resume_stage: 'story_bible',
      source_files: characterContract.source_files,
      findings: characterContract.findings,
      advisories: characterContract.advisories,
    };
  }
  const target = activeChapterTarget(task);
  if (!target) return { status: 'not_applicable', reason: 'chapter_identity_missing' };
  const targetValidation = validateLongChapterTargetV2(target, {
    projectRoot: root,
    workflowId: String((task || {}).workflow_id || ''),
  });
  if (!targetValidation.ok) {
    return {
      status: 'blocked_long_chapter_target_incomplete',
      blocking: true,
      reason: 'stage_execution.chapter_target 或 active_chapter_target 不是完整的 V2 目标；必须先冻结完整目标，禁止从 scope/目录推断。',
      missing_fields: targetValidation.missing_fields,
    };
  }
  const chapter = Number(target.volume_chapter_no) || 0;
  const globalChapter = Number(target.global_chapter_no) || 0;
  const volume = String(target.volume || '');
  const dualIdentity = formatLongChapterDisplay(target);
  const authorityEntries = [];
  if (['chapter_brief', 'brief_review'].includes(stageId)) {
    const outlineAuthority = loadFrozenOutlineAuthority(root, target);
    if (outlineAuthority.status !== 'loaded') return outlineAuthority;
    authorityEntries.push(makeInlineSource(
      'frozen_chapter_outline',
      String(target.outline_path || ''),
      'frozen_chapter_outline',
      outlineAuthority.content,
    ));
  }
  if (['brief_review', 'prose', 'prose_acceptance'].includes(stageId)) {
    const briefAuthority = loadCurrentBriefAuthority(root, target);
    if (briefAuthority.status !== 'loaded') return briefAuthority;
    authorityEntries.push(makeInlineSource(
      'current_chapter_brief',
      String(target.contract_path || ''),
      'current_chapter_brief',
      briefAuthority.content,
    ));
  }
  const contextPack = buildContextPack(root, chapter, volume, target, stageId);
  const machineState = (task && task.machine) || {};
  const proseAttemptNo = Number((((task || {}).stage_execution || {}).attempt_no) || 0);
  const storedBlockingFindings = loadProseRetryFindings(root, task, target);
  const transitionValidation = (((task || {}).lifecycle_graph || {}).last_transition_validation) || {};
  const isReviewReturn = String(machineState.last_transition || '') === 'review_failed_return_to_asset'
    || (transitionValidation.allowed === true
      && String(transitionValidation.rule || '') === 'required_review_failure_return'
      && String(transitionValidation.to || '') === String(stageId || ''));
  const shouldIncludeRetryFindings = (stageId === 'chapter_brief' && isReviewReturn)
    || (stageId === 'prose' && (proseAttemptNo > 1 || isReviewReturn));
  const retryFindings = shouldIncludeRetryFindings && Array.isArray(storedBlockingFindings)
    ? storedBlockingFindings.filter((item) => item && typeof item === 'object')
    : [];
  if (retryFindings.length > 0) {
    contextPack.gate = {
      ...(contextPack.gate || {}),
      status: 'fail',
      blockingFindings: [
        ...(Array.isArray(((contextPack || {}).gate || {}).blockingFindings) ? contextPack.gate.blockingFindings : []),
        ...retryFindings,
      ],
    };
  }
  const contextSources = contextPack && contextPack.sourceFiles ? contextPack.sourceFiles : {};
  const outlineMismatch = String(contextSources.outline || '') !== String(target.outline_path || '');
  const contractMismatch = stageId === 'chapter_brief'
    ? Boolean(contextSources.currentContract) && String(contextSources.currentContract) !== String(target.contract_path || '')
    : String(contextSources.currentContract || '') !== String(target.contract_path || '');
  if (outlineMismatch || contractMismatch) {
    return {
      status: 'blocked_long_chapter_context_target_mismatch',
      blocking: true,
      reason: '章节上下文包未精确绑定冻结目标的细纲与章节契约；禁止读取同章遗留副本或越出项目目录。',
      chapter_identity: dualIdentity,
      chapter_target_v2: target,
      actual_sources: contextSources,
    };
  }
  const draft = ['prose_acceptance', 'chapter_commit'].includes(stageId)
    || (stageId === 'prose' && retryFindings.length > 0)
    ? resolveChapterDraft(root, task, target)
    : '';
  if (['prose_acceptance', 'chapter_commit'].includes(stageId) && !draft) {
    return {
      status: 'blocked_long_chapter_candidate_missing',
      blocking: true,
      reason: '当前章节候选正文不存在；禁止回退审阅旧正式稿或章节契约。',
      chapter_identity: dualIdentity,
      chapter_target_v2: target,
      expected_candidate_draft: String(target.candidate_draft_path || ''),
    };
  }
  if (stageId === 'chapter_commit') {
    const contractFile = path.join(root, String(target.contract_path || ''));
    const length = evaluateLongChapterLength(
      fs.existsSync(contractFile) && fs.statSync(contractFile).isFile() ? fs.readFileSync(contractFile, 'utf8') : '',
      fs.readFileSync(draft, 'utf8'),
    );
    if (length.status !== 'pass') {
      return {
        status: 'blocked_long_chapter_length_contract',
        blocking: true,
        reason: length.message,
        chapter_identity: dualIdentity,
        chapter_target_v2: target,
        length_contract: length,
        resume_stage: 'prose',
      };
    }
  }
  const explicitBudget = positiveInt(options.tokenBudget);
  const requiredAuthorityTokens = authorityEntries.reduce((sum, entry) => sum + entry.estimated_tokens, 0);
  if (explicitBudget && explicitBudget < requiredAuthorityTokens) {
    return {
      status: 'blocked_required_context_budget',
      blocking: true,
      reason: '当前章冻结细纲与待审 Brief 均为不可截断的权威输入；预算不足时禁止生成残缺上下文。',
      token_budget: explicitBudget,
      required_tokens: requiredAuthorityTokens,
      required_sources: authorityEntries.map(publicSource),
    };
  }
  const tokenBudget = explicitBudget || Math.max(DEFAULT_TOKEN_BUDGET, requiredAuthorityTokens + 1500);
  const entries = [...authorityEntries];
  let remaining = tokenBudget - requiredAuthorityTokens;

  const contextText = JSON.stringify(compactContextPack(contextPack), null, 2);
  const compactContext = compactToTokens(contextText, Math.min(remaining, 3000));
  const contextEntry = {
    id: 'chapter_context',
    path: contextPack.__path || '',
    kind: 'chapter_context',
    content: compactContext,
    estimated_tokens: estimateTokens(compactContext),
    truncated: compactContext !== contextText,
  };
  entries.push(contextEntry);
  remaining -= contextEntry.estimated_tokens;

  if (draft) {
    const draftText = fs.readFileSync(draft, 'utf8');
    const compactDraft = compactToTokens(draftText, Math.max(500, remaining));
    entries.push({ id: 'current_chapter_draft', path: relative(root, draft), kind: 'current_draft', content: compactDraft, estimated_tokens: estimateTokens(compactDraft), truncated: compactDraft !== draftText });
  }

  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'long-write'}`);
  const base = `${taskDir}/context-packets/${stageId}/chapter-${String(chapter).padStart(3, '0')}`;
  const packetMd = `${base}/stage-context.md`;
  const packetJson = `${base}/stage-context.json`;
  const markdown = renderMarkdown({ task, stageId, chapter, globalChapter, volume, dualIdentity, target, tokenBudget, entries });
  atomicWriteText(path.join(root, packetMd), markdown);
  atomicWriteJson(path.join(root, packetJson), {
    schemaVersion: '1.0.0',
    workflow_id: String((task || {}).workflow_id || ''),
    workflow_type: 'long_write',
    stage_id: stageId,
    chapter,
    global_chapter_no: globalChapter,
    volume,
    chapter_identity: dualIdentity,
    chapter_target_v2: target,
    packet_md: packetMd,
    packet_json: packetJson,
    token_budget: tokenBudget,
    estimated_tokens: entries.reduce((sum, entry) => sum + entry.estimated_tokens, 0),
    source_files: entries.map(stageSource),
    excludes: stageContextExcludes(stageId),
    created_at: new Date().toISOString(),
  });
  return {
    status: 'assembled',
    packet_md: packetMd,
    packet_json: packetJson,
    chapter,
    global_chapter_no: globalChapter,
    volume,
    chapter_identity: dualIdentity,
    chapter_target_v2: target,
    estimated_tokens: entries.reduce((sum, entry) => sum + entry.estimated_tokens, 0),
    token_budget: tokenBudget,
    source_files: entries.map(stageSource),
    draft: draft ? relative(root, draft) : '',
  };
}

function buildDetailOutlineReviewContextPacket({ root, task, stageId, options }) {
  const execution = ((task || {}).stage_execution || {});
  const targets = Array.isArray(execution.review_targets) && execution.review_targets.length > 0
    ? execution.review_targets
    : Array.isArray((task || {}).detail_outline_review_targets) ? task.detail_outline_review_targets : [];
  if (targets.length === 0) {
    return {
      status: 'blocked_long_detail_outline_review_targets_missing',
      blocking: true,
      reason: '细纲复核缺少冻结的 review_targets；禁止从目录扫描推断审阅范围。',
    };
  }

  const reviewFiles = [];
  const authorityPaths = [];
  for (const target of targets) {
    const relativePath = normalizeProjectRelative(target && target.outline_path);
    const resolved = resolveProjectFile(root, relativePath);
    if (!relativePath || !resolved) {
      return {
        status: 'blocked_long_detail_outline_review_target_missing',
        blocking: true,
        reason: '细纲复核目标不存在或越出项目目录。',
        outline_path: relativePath,
      };
    }
    const content = fs.readFileSync(resolved, 'utf8');
    const digest = crypto.createHash('sha256').update(content).digest('hex');
    if (String((target || {}).outline_sha256 || '') !== digest) {
      return {
        status: 'blocked_long_detail_outline_review_target_drift',
        blocking: true,
        reason: '细纲内容已变化，必须先刷新 review_targets，禁止审阅旧哈希。',
        outline_path: relativePath,
        expected_sha256: String((target || {}).outline_sha256 || ''),
        actual_sha256: digest,
      };
    }
    reviewFiles.push(makeInlineSource(`review_target_${reviewFiles.length + 1}`, relativePath, 'detail_outline', content));
    const authorityPath = normalizeProjectRelative(path.posix.join(path.posix.dirname(relativePath), '卷纲.md'));
    if (authorityPath && !authorityPaths.includes(authorityPath)) authorityPaths.push(authorityPath);
  }

  const authorityFiles = [];
  for (const relativePath of authorityPaths) {
    const resolved = resolveProjectFile(root, relativePath);
    if (!resolved) {
      return {
        status: 'blocked_long_detail_outline_review_authority_missing',
        blocking: true,
        reason: '细纲复核缺少同卷卷纲权威；禁止让模型自行选择上游依据。',
        authority_path: relativePath,
      };
    }
    authorityFiles.push(makeInlineSource(`volume_outline_${authorityFiles.length + 1}`, relativePath, 'volume_outline_authority', fs.readFileSync(resolved, 'utf8')));
  }

  const sources = [...authorityFiles, ...reviewFiles];
  const requiredTokens = sources.reduce((sum, source) => sum + source.estimated_tokens, 0);
  const explicitBudget = positiveInt(options && options.tokenBudget);
  if (explicitBudget && explicitBudget < requiredTokens) {
    return {
      status: 'blocked_required_context_budget',
      blocking: true,
      reason: '细纲语义复核所需的卷纲与目标细纲均为必需资产，预算不足时禁止截断后继续。',
      token_budget: explicitBudget,
      required_tokens: requiredTokens,
    };
  }
  const tokenBudget = explicitBudget || requiredTokens;
  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'long-write'}`);
  const attemptId = safePathSegment(execution.stage_attempt_id || 'attempt-pending');
  const base = `${taskDir}/context-packets/${stageId}/${attemptId}`;
  const packetMd = `${base}/stage-context.md`;
  const packetJson = `${base}/stage-context.json`;
  const markdown = renderDetailOutlineReviewMarkdown({ task, sources, targets, requiredTokens });
  atomicWriteText(path.join(root, packetMd), markdown);
  atomicWriteJson(path.join(root, packetJson), {
    schemaVersion: '1.0.0',
    workflow_id: String((task || {}).workflow_id || ''),
    workflow_type: 'long_write',
    stage_id: stageId,
    packet_md: packetMd,
    packet_json: packetJson,
    token_budget: tokenBudget,
    estimated_tokens: requiredTokens,
    authority_files: authorityFiles.map((source) => source.path),
    review_targets: targets.map((target) => ({
      outline_path: String((target || {}).outline_path || ''),
      outline_sha256: String((target || {}).outline_sha256 || ''),
    })),
    source_files: sources.map(publicSource),
    excludes: ['其他卷纲与细纲', '正文与旧聊天', '任务日志和历史回执', '平台脚本源码'],
    created_at: new Date().toISOString(),
  });
  return {
    status: 'assembled',
    packet_md: packetMd,
    packet_json: packetJson,
    estimated_tokens: requiredTokens,
    token_budget: tokenBudget,
    source_files: sources.map(publicSource),
    review_target_count: reviewFiles.length,
    authority_files: authorityFiles.map((source) => source.path),
  };
}

function buildDetailOutlineRevisionContextPacket({ root, task, stageId, options }) {
  const execution = ((task || {}).stage_execution || {});
  const failure = ((task || {}).detail_outline_review_failure || {});
  const failedTargets = Array.from(new Set((Array.isArray(failure.failed_targets) ? failure.failed_targets : [])
    .map(normalizeProjectRelative).filter(Boolean)));
  const revisionTargets = Array.from(new Set((Array.isArray(execution.revision_targets) ? execution.revision_targets : [])
    .map(normalizeProjectRelative).filter(Boolean)));
  if (failedTargets.length === 0 || JSON.stringify(revisionTargets) !== JSON.stringify(failedTargets)) {
    return {
      status: 'blocked_long_detail_outline_revision_scope_invalid',
      blocking: true,
      reason: '细纲回炉必须精确绑定上一轮审阅未通过目标；禁止扩大到整卷或其他细纲。',
      failed_targets: failedTargets,
      revision_targets: revisionTargets,
    };
  }
  const frozenTargets = new Map((Array.isArray((task || {}).detail_outline_review_targets)
    ? task.detail_outline_review_targets : [])
    .map((target) => [normalizeProjectRelative(target && target.outline_path), target]));
  const reviewFiles = [];
  const authorityPaths = [];
  for (const relativePath of failedTargets) {
    const target = frozenTargets.get(relativePath);
    const resolved = resolveProjectFile(root, relativePath);
    if (!target || !resolved) {
      return {
        status: 'blocked_long_detail_outline_revision_target_missing',
        blocking: true,
        reason: '细纲回炉目标缺少冻结身份或文件不存在。',
        outline_path: relativePath,
      };
    }
    const content = fs.readFileSync(resolved, 'utf8');
    const digest = crypto.createHash('sha256').update(content).digest('hex');
    if (String((target || {}).outline_sha256 || '') !== digest) {
      return {
        status: 'blocked_long_detail_outline_revision_target_drift',
        blocking: true,
        reason: '待回炉细纲已在审阅后发生变化；必须重新审阅，禁止套用旧意见。',
        outline_path: relativePath,
        expected_sha256: String((target || {}).outline_sha256 || ''),
        actual_sha256: digest,
      };
    }
    reviewFiles.push(makeInlineSource(`revision_target_${reviewFiles.length + 1}`, relativePath, 'detail_outline_revision_target', content));
    const authorityPath = normalizeProjectRelative(path.posix.join(path.posix.dirname(relativePath), '卷纲.md'));
    if (authorityPath && !authorityPaths.includes(authorityPath)) authorityPaths.push(authorityPath);
  }

  const authorityFiles = [];
  for (const relativePath of authorityPaths) {
    const resolved = resolveProjectFile(root, relativePath);
    if (!resolved) {
      return {
        status: 'blocked_long_detail_outline_revision_authority_missing',
        blocking: true,
        reason: '细纲回炉缺少同卷卷纲权威。',
        authority_path: relativePath,
      };
    }
    authorityFiles.push(makeInlineSource(`volume_outline_${authorityFiles.length + 1}`, relativePath, 'volume_outline_authority', fs.readFileSync(resolved, 'utf8')));
  }

  const reviewPacketPath = normalizeProjectRelative(failure.result_packet_path);
  const reviewPacketFile = resolveProjectFile(root, reviewPacketPath);
  if (!reviewPacketFile) {
    return {
      status: 'blocked_long_detail_outline_revision_review_evidence_missing',
      blocking: true,
      reason: '细纲回炉缺少上一轮审阅结果包；禁止凭聊天记忆修订。',
      result_packet_path: reviewPacketPath,
    };
  }
  const reviewPacket = readJson(reviewPacketFile);
  const quality = (((reviewPacket || {}).outputs || {}).detail_outline_quality) || {};
  const failedSet = new Set(failedTargets);
  const identities = Array.isArray(quality.identities)
    ? quality.identities.filter((item) => failedSet.has(normalizeProjectRelative((item || {}).outline_path)))
    : [];
  const identityPaths = identities.map((item) => normalizeProjectRelative((item || {}).outline_path));
  if (!reviewPacket || reviewPacket.__error
      || String(reviewPacket.workflow_id || '') !== String((task || {}).workflow_id || '')
      || String(reviewPacket.stage_id || '') !== 'detail_outline_review'
      || String(reviewPacket.review_decision || '') !== 'revise'
      || identities.length !== failedTargets.length
      || failedTargets.some((target) => !identityPaths.includes(target))) {
    return {
      status: 'blocked_long_detail_outline_revision_review_evidence_invalid',
      blocking: true,
      reason: '上一轮审阅结果包与当前工作流或未通过目标不一致。',
      result_packet_path: reviewPacketPath,
    };
  }
  const findingsContent = JSON.stringify({
    review_decision: 'revise',
    handoff_summary: String(reviewPacket.handoff_summary || ''),
    next_recommendation: String(reviewPacket.next_recommendation || ''),
    identities: identities.map((item) => ({
      outline_path: normalizeProjectRelative((item || {}).outline_path),
      status: String((item || {}).status || ''),
      findings: Array.isArray((item || {}).findings) ? item.findings : [],
    })),
  }, null, 2);
  const findingsSource = makeInlineSource('detail_outline_review_findings', reviewPacketPath, 'detail_outline_review_findings', findingsContent);
  const sources = [...authorityFiles, findingsSource, ...reviewFiles];
  const requiredTokens = sources.reduce((sum, source) => sum + source.estimated_tokens, 0);
  const explicitBudget = positiveInt(options && options.tokenBudget);
  if (explicitBudget && explicitBudget < requiredTokens) {
    return {
      status: 'blocked_required_context_budget',
      blocking: true,
      reason: '细纲回炉所需的卷纲、审阅意见和目标细纲均为必需资产，预算不足时禁止截断。',
      token_budget: explicitBudget,
      required_tokens: requiredTokens,
    };
  }
  const tokenBudget = explicitBudget || requiredTokens;
  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'long-write'}`);
  const attemptId = safePathSegment(execution.stage_attempt_id || 'attempt-pending');
  const base = `${taskDir}/context-packets/${stageId}/${attemptId}`;
  const packetMd = `${base}/stage-context.md`;
  const packetJson = `${base}/stage-context.json`;
  const markdown = renderDetailOutlineRevisionMarkdown({ task, sources, failedTargets, requiredTokens });
  atomicWriteText(path.join(root, packetMd), markdown);
  atomicWriteJson(path.join(root, packetJson), {
    schemaVersion: '1.0.0',
    workflow_id: String((task || {}).workflow_id || ''),
    workflow_type: 'long_write',
    stage_id: stageId,
    packet_md: packetMd,
    packet_json: packetJson,
    token_budget: tokenBudget,
    estimated_tokens: requiredTokens,
    authority_files: authorityFiles.map((source) => source.path),
    review_result_packet: reviewPacketPath,
    revision_targets: failedTargets,
    source_files: sources.map(publicSource),
    excludes: ['已通过细纲', '其他卷纲与细纲', '正文与旧聊天', '任务日志与平台脚本源码'],
    created_at: new Date().toISOString(),
  });
  return {
    status: 'assembled',
    packet_md: packetMd,
    packet_json: packetJson,
    estimated_tokens: requiredTokens,
    token_budget: tokenBudget,
    source_files: sources.map(publicSource),
    revision_target_count: reviewFiles.length,
    authority_files: authorityFiles.map((source) => source.path),
    review_result_packet: reviewPacketPath,
  };
}

function makeInlineSource(id, relativePath, kind, content) {
  return {
    id,
    path: relativePath,
    kind,
    content,
    content_digest: crypto.createHash('sha256').update(content).digest('hex'),
    estimated_tokens: estimateTokens(content),
    truncated: false,
  };
}

function publicSource(source) {
  return {
    id: source.id,
    path: source.path,
    kind: source.kind,
    content_digest: source.content_digest,
    estimated_tokens: source.estimated_tokens,
    truncated: false,
  };
}

function stageSource(source) {
  return {
    id: source.id,
    path: source.path,
    kind: source.kind,
    ...(source.content_digest ? { content_digest: source.content_digest } : {}),
    estimated_tokens: source.estimated_tokens,
    truncated: Boolean(source.truncated),
  };
}

function stageContextExcludes(stageId) {
  return ['chapter_brief', 'brief_review'].includes(stageId)
    ? ['其他总纲/卷纲/细纲原文', '完整任务日志和历史回执', '平台脚本源码', '无关章节正文', '旧聊天转录']
    : ['完整总纲/卷纲/细纲原文', '完整任务日志和历史回执', '平台脚本源码', '无关章节正文', '旧聊天转录'];
}

function loadFrozenOutlineAuthority(root, target) {
  const outlinePath = normalizeProjectRelative((target || {}).outline_path);
  const outlineFile = resolveProjectFile(root, outlinePath);
  if (!outlinePath || !outlineFile) {
    return {
      status: 'blocked_long_chapter_outline_authority_missing',
      blocking: true,
      reason: '冻结章节细纲不存在或越出项目目录；禁止从目录、旧 Brief 或聊天内容推断章节权威。',
      outline_path: outlinePath,
    };
  }
  const content = fs.readFileSync(outlineFile, 'utf8');
  const actualSha256 = crypto.createHash('sha256').update(content).digest('hex');
  const expectedSha256 = String((target || {}).outline_sha256 || '');
  if (actualSha256 !== expectedSha256) {
    return {
      status: 'blocked_long_chapter_outline_authority_drift',
      blocking: true,
      reason: '当前章细纲内容与冻结哈希不一致；必须先刷新章节目标，禁止使用漂移后的细纲继续。',
      outline_path: outlinePath,
      expected_sha256: expectedSha256,
      actual_sha256: actualSha256,
    };
  }
  return { status: 'loaded', content };
}

function loadCurrentBriefAuthority(root, target) {
  const contractPath = normalizeProjectRelative((target || {}).contract_path);
  const contractFile = resolveProjectFile(root, contractPath);
  if (!contractPath || !contractFile) {
    return {
      status: 'blocked_long_chapter_brief_authority_missing',
      blocking: true,
      reason: 'Brief 审阅缺少冻结目标指向的当前章节 Brief；禁止审阅旧契约或推断内容。',
      contract_path: contractPath,
    };
  }
  return { status: 'loaded', content: fs.readFileSync(contractFile, 'utf8') };
}

function renderDetailOutlineReviewMarkdown({ task, sources, targets, requiredTokens }) {
  const lines = [
    '# 长篇细纲复核权威上下文包',
    '',
    `> workflow=${String((task || {}).workflow_id || '')} stage=detail_outline_review`,
    `> 本批 ${targets.length} 项，约 ${requiredTokens} tokens。卷纲是上游权威；细纲与卷纲冲突时必须判为 revise，不得用细纲反向解释卷纲。`,
    '> 只审阅本包列出的细纲；不得读取其他卷、其他章节、正文、旧聊天或历史回执。',
    '',
  ];
  for (const source of sources) {
    lines.push(`## ${source.kind}: ${source.path}`, '', source.content, '');
  }
  return `${lines.join('\n')}\n`;
}

function renderDetailOutlineRevisionMarkdown({ task, sources, failedTargets, requiredTokens }) {
  const lines = [
    '# 长篇细纲定向回炉权威上下文包',
    '',
    `> workflow=${String((task || {}).workflow_id || '')} stage=stage_detail_outline`,
    `> 本批只允许修订 ${failedTargets.length} 个未通过细纲，约 ${requiredTokens} tokens。卷纲是上游权威，审阅意见是本轮缺陷清单。`,
    '> 必须落实每条 blocking 意见；不得修改卷纲、已通过细纲、正文或追踪状态，不得用新剧情替代卷纲责任。',
    '',
  ];
  for (const source of sources) {
    lines.push(`## ${source.kind}: ${source.path}`, '', source.content, '');
  }
  return `${lines.join('\n')}\n`;
}

function normalizeProjectRelative(value) {
  const normalized = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
  if (!normalized || path.posix.isAbsolute(normalized) || normalized.split('/').includes('..')) return '';
  return normalized;
}

function resolveProjectFile(root, relativePath) {
  if (!relativePath) return '';
  const candidate = path.resolve(root, relativePath);
  const rel = path.relative(root, candidate);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return '';
  try {
    if (!fs.statSync(candidate).isFile()) return '';
    const realRoot = fs.realpathSync(root);
    const realCandidate = fs.realpathSync(candidate);
    const realRel = path.relative(realRoot, realCandidate);
    if (!realRel || realRel.startsWith('..') || path.isAbsolute(realRel)) return '';
    return candidate;
  } catch (_) {
    return '';
  }
}

function safePathSegment(value) {
  return String(value || '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'attempt-pending';
}

// Compatibility shim — older callers expected to pass root/task/stageId
// and infer chapter/volume from frozen target. Returns the chapter number
// (volume-local) of the active V2 target, never from scope/user_goal.
function inferLongChapter(root, task, stageId) {
  const target = activeChapterTarget(task);
  if (LONG_STAGES.has(stageId) && target) return Number(target.volume_chapter_no) || 0;
  return 0;
}

function inferVolume(task) {
  const target = activeChapterTarget(task);
  return target ? String(target.volume || '') : '';
}

function buildContextPack(root, chapter, volume, target, stageId) {
  const args = [path.join(__dirname, '..', 'context-pack-build.js'), root, '--chapter', String(chapter), '--mode', 'writing', '--write', '--json'];
  if (volume) args.push('--volume', volume);
  args.push('--outline-path', String((target || {}).outline_path || ''));
  const contractPath = stageId === 'chapter_brief'
    ? unusedChapterBriefContractPath(root, target)
    : String((target || {}).contract_path || '');
  args.push('--contract-path', contractPath);
  const run = spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  const parsed = parseJson(run.stdout) || { gate: { status: 'fail', blockingFindings: [{ code: 'context_pack_failed', message: String(run.stderr || '').slice(0, 500) }] }, summary: {}, sourceFiles: {} };
  parsed.__path = contextPackRelative(chapter, volume);
  return parsed;
}

function unusedChapterBriefContractPath(root, target) {
  const targetId = String((target || {}).target_id || '').replace(/[^A-Za-z0-9]+/g, '').slice(-16) || 'current';
  const base = `追踪/workflow/.chapter-brief-output-not-input/${targetId}`;
  let candidate = `${base}.md`;
  let suffix = 0;
  while (fs.existsSync(path.join(root, candidate))) {
    suffix += 1;
    candidate = `${base}.${suffix}.md`;
  }
  return candidate;
}

function compactContextPack(pack) {
  return {
    target: pack.target || {}, gate: pack.gate || {}, sourceFiles: pack.sourceFiles || {},
    mustCarryForward: ((pack.summary || {}).mustCarryForward || []).slice(0, 20),
    forbiddenChanges: ((pack.summary || {}).forbiddenChanges || []).slice(0, 15),
    openForeshadows: ((pack.summary || {}).openForeshadows || []).slice(0, 20),
    characterState: ((pack.summary || {}).characterState || []).slice(0, 20),
    recentStateDelta: ((pack.summary || {}).recentStateDelta || []).slice(0, 12),
    timeline: ((pack.summary || {}).timeline || []).slice(0, 12),
    continuityQuestions: ((pack.summary || {}).continuityQuestions || []).slice(0, 12),
  };
}

// V2 file resolution: use exact draft_path / contract_path / candidate_draft_path
// from the active target. Fall back only when none of those exist on disk
// (legacy non-V2 path) — and even then, never trust scope/user_goal.
function resolveChapterDraft(root, task, target) {
  if (!target || typeof target !== 'object') return '';
  const candidate = target.candidate_draft_path ? path.join(root, target.candidate_draft_path) : '';
  try {
    if (candidate && fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  } catch (_) { /* ignore */ }
  return '';
}

function loadProseRetryFindings(root, task, target) {
  const machineFindings = ((task || {}).machine || {}).last_blocking_findings;
  if (Array.isArray(machineFindings) && machineFindings.length > 0) return machineFindings;
  const relativePacket = String((((task || {}).machine || {}).last_result_packet) || '');
  if (!relativePacket) return [];
  const packetFile = path.resolve(root, relativePacket);
  const relativePath = path.relative(root, packetFile);
  if (!relativePath || relativePath.startsWith('..') || path.isAbsolute(relativePath)) return [];
  const packet = readJson(packetFile);
  if (!packet
    || String(packet.workflow_id || '') !== String((task || {}).workflow_id || '')
    || String(packet.stage_id || '') !== 'prose_acceptance'
    || !['blocked', 'rejected'].includes(String(packet.step_status || ''))
    || String(((packet.chapter_target || {}).target_id) || '') !== String((target || {}).target_id || '')
    || !Array.isArray(packet.blocking_findings)) return [];
  return packet.blocking_findings;
}

function contextPackRelative(chapter, volume) {
  return `${volume ? `追踪/context-pack/${volume}` : '追踪/context-pack'}/第${String(chapter).padStart(3, '0')}章.json`;
}

function renderMarkdown({ task, stageId, chapter, globalChapter, volume, dualIdentity, target, tokenBudget, entries }) {
  const lines = [
    `# 长篇当前章节最小上下文包`,
    ``,
    `> workflow=${task.workflow_id || ''} stage=${stageId} chapter=${chapter} global_chapter_no=${globalChapter} volume=${volume || ''}`,
    `> 章节身份：${dualIdentity}`,
    `> target_id=${target.target_id || ''}`,
    `> 预算 ${tokenBudget} tokens。只使用包内内容；发现 gate.fail 时修复缺口，不得自由扩读。`,
    ...(['chapter_brief', 'brief_review'].includes(stageId)
      ? [`> frozen_chapter_outline 是完整且不可截断的章节权威；${stageId === 'brief_review' ? 'current_chapter_brief 必须逐项对照该细纲审阅。' : '旧章节 Brief/契约不得覆盖细纲。'}`]
      : []),
    ...(['prose', 'prose_acceptance'].includes(stageId)
      ? [`> current_chapter_brief 是完整且不可截断的正文权威；正文不得用压缩摘要、旧候选或记忆替代 Brief。`]
      : []),
    ``,
  ];
  for (const entry of entries) {
    lines.push(`## ${entry.id}`, `路径：${entry.path || '内嵌摘要'}`, ``, entry.content, ``);
  }
  lines.push(`## 章节目标（V2）`, `- outline_path: ${target.outline_path || ''}`, `- outline_sha256: ${target.outline_sha256 || ''}`, `- volume: ${target.volume || ''}`, `- volume_chapter_no: ${target.volume_chapter_no || ''}`, `- global_chapter_no: ${target.global_chapter_no || ''}`, `- contract_path: ${target.contract_path || ''}`, `- draft_path: ${target.draft_path || ''}`, `- candidate_draft_path: ${target.candidate_draft_path || ''}`);
  lines.push(
    `## 禁止扩读`,
    `- ${['chapter_brief', 'brief_review'].includes(stageId) ? '本包之外的总纲、卷纲、细纲原文' : '完整总纲、卷纲、细纲原文'}`,
    `- 完整任务日志和历史回执`,
    `- 平台脚本源码`,
    `- 无关章节正文和旧聊天`,
  );
  return `${lines.join('\n')}\n`;
}

function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function positiveInt(value) { const n = Number(value); return Number.isInteger(n) && n > 0 ? n : 0; }

module.exports = {
  LONG_STAGES,
  LONG_OUTLINE_REVIEW_STAGES,
  LONG_OUTLINE_REVISION_STAGES,
  activeChapterTarget,
  buildLongStageContextPacket,
  inferLongChapter,
  inferVolume,
  resolveChapterDraft,
};
