'use strict';

// V3 accepted-planning feedback transaction.
//
// The author confirmation only records intent. This service is the subsequent
// canonical-write boundary: it validates every required planning candidate,
// checks that each canonical source still matches the accepted snapshot, and
// commits the complete set through one chapter transaction. It never mutates
// task.json; the V3 Engine applies its returned StageResult.

const fs = require('fs');
const path = require('path');
const { acceptTransaction, prepareTransaction } = require('../chapter-commit-store');
const { atomicWriteJson } = require('../workflow-state-store');
const {
  analyzeShortCharacterContract,
  projectShortCharacterMemory,
} = require('../short-character-contract');
const {
  advanceShortPlanRevision,
  ensureShortProjectState,
  readShortProjectState,
  resolveShortStateRelative,
} = require('../short-project-state');
const {
  analyzeShortOutlineNarrativeQuality,
  inferPlannedSections,
  outlineSections,
} = require('../short-plan-contract');
const {
  hashFile,
  inferProjectTitle,
  safeProjectFile,
  safeSegment,
} = require('./planning');
const { stageResult } = require('../workflow-v3/contracts');

const PLANNING_ASSETS = new Set(['素材卡.md', '设定.md', '小节大纲.md']);

function finalizeFeedbackPlanningPatch(context = {}) {
  const root = path.resolve(String(context.projectRoot || ''));
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = 'feedback_apply_patch';
  const plan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
  const expectedAssets = normalizeAssets((((plan || {}).projection_plan || {}).planning_assets));
  const stagedAssets = normalizeStagedAssets(context.stagedAssets);
  const actualAssets = stagedAssets.map(item => item.canonical);

  if (!String(plan.plan_id || '') || String(plan.projection_status || '') !== 'pending' || !expectedAssets.length) {
    return blocked(stageId, 'feedback_planning_acceptance_missing', {
      instruction: '当前没有待回写的已确认规划方案；重新显示任务状态后继续。',
    });
  }
  const setCheck = validateExpectedAssetSet(expectedAssets, actualAssets);
  if (!setCheck.ok) {
    return blocked(stageId, 'planning_asset_set_incomplete', {
      missing_assets: setCheck.missing,
      unexpected_assets: setCheck.unexpected,
      expected_assets: expectedAssets,
      actual_assets: actualAssets,
      instruction: '只补齐已确认方案列出的全部暂存规划资产后重跑；不要修改 Brief 或正文。',
    });
  }
  const sourceCheck = validateSourceBefore(root, expectedAssets, (((plan || {}).projection_plan || {}).source_before));
  if (!sourceCheck.ok) {
    return blocked(stageId, 'planning_asset_source_stale', {
      stale_assets: sourceCheck.stale,
      missing_source_receipts: sourceCheck.missing_receipts,
      instruction: '确认方案前的规划资产已变化；重新分析并确认方案，不能覆盖较新的规划。',
    });
  }
  const stagedCheck = validateStagedCandidates(root, stagedAssets);
  if (!stagedCheck.ok) {
    return blocked(stageId, 'planning_asset_candidate_invalid', {
      missing_assets: stagedCheck.missing,
      empty_assets: stagedCheck.empty,
      invalid_assets: stagedCheck.invalid,
      instruction: '只修复当前暂存规划资产，保持正式设定和大纲不变后重跑。',
    });
  }
  const quality = validatePlanningCandidates(root, stagedAssets, plan);
  if (!quality.ok) {
    return blocked(stageId, quality.code, {
      findings: quality.findings,
      planning_target: quality.planning_target,
      instruction: quality.instruction,
    });
  }

  const reusable = findReusableCommit(root, task, expectedAssets);
  let commit = reusable;
  if (!commit) {
    const attempt = safeSegment((((task || {}).stage_execution || {}).stage_attempt_id) || 'attempt');
    const manifestRel = `${String(task.task_dir || '').replace(/\\/g, '/')}/artifacts/planning-commits/feedback_apply_patch-${attempt}.manifest.json`;
    const manifestFile = safeProjectFile(root, manifestRel);
    if (!manifestFile) {
      return blocked(stageId, 'feedback_planning_manifest_path_invalid', {
        instruction: '任务暂存目录无效，无法准备规划回写事务。',
      });
    }
    atomicWriteJson(manifestFile, {
      schemaVersion: '1.0.0',
      workflow_id: String(task.workflow_id || ''),
      provenance: {
        workflow_id: String(task.workflow_id || ''),
        task_family_id: String(task.task_family_id || ''),
        branch_id: String(task.branch_id || task.workflow_id || ''),
        stage_attempt_id: String((((task || {}).stage_execution || {}).stage_attempt_id) || ''),
        acceptance_status: 'accepted',
      },
      volume: '短篇规划反馈',
      chapter: 1,
      gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
      artifacts: stagedAssets.map(item => ({
        role: 'feedback_planning_patch',
        required: true,
        staged: item.staged,
        target: item.canonical,
      })),
      facts: [],
    });
    try {
      const prepared = prepareTransaction(root, manifestRel);
      const accepted = acceptTransaction(root, prepared.transaction_id);
      commit = readCommit(root, accepted.commit_id);
    } catch (error) {
      return retryable(stageId, 'feedback_planning_transaction_blocked', {
        failure_family: String((error && error.status) || 'planning_transaction'),
        detail: String((error && error.message) || error),
        instruction: '暂存规划资产已保留；修复事务阻断后重跑当前阶段，不要重新生成内容。',
      });
    }
  }

  const projection = projectCanonicalPlanningState(root, task, expectedAssets);
  if (!projection.ok) {
    return retryable(stageId, projection.code, {
      failure_family: 'planning_projection',
      commit_id: String(commit.commit_id || ''),
      detail: projection.detail,
      instruction: '规划资产已安全提交，但状态或人物记忆投影未完成；修复投影后重跑当前阶段，不要重新生成内容。',
    });
  }
  const artifacts = transactionArtifacts(commit, expectedAssets);
  return stageResult({
    kind: 'completed',
    code: 'short_feedback_planning_patch_accepted',
    stage_id: stageId,
    feedback_id: String(plan.feedback_id || ''),
    impact_level: String(plan.impact_level || ''),
    affected_sections: normalizeSections(plan.affected_sections),
    changed_assets: expectedAssets,
    changed_files: expectedAssets,
    planning_transaction: {
      commit_id: String(commit.commit_id || ''),
      commit_file: String(commit.commit_file || ''),
      artifacts,
      reused: reusable !== null,
    },
    project_state: projection.project_state,
    character_memory: projection.character_memory,
    title_lock: projection.title_lock,
  });
}

function validateExpectedAssetSet(expected, actual) {
  const wanted = normalizeAssets(expected);
  const got = normalizeAssets(actual);
  return {
    ok: wanted.length === got.length && wanted.every((item, index) => item === got[index]),
    missing: wanted.filter(item => !got.includes(item)),
    unexpected: got.filter(item => !wanted.includes(item)),
  };
}

function validateSourceBefore(root, expected, sourceBefore) {
  const byPath = new Map((Array.isArray(sourceBefore) ? sourceBefore : []).map(item => [
    normalizeAsset((item || {}).path),
    String((item || {}).sha256 || ''),
  ]));
  const stale = [];
  const missingReceipts = [];
  for (const canonical of expected) {
    const expectedDigest = byPath.get(canonical);
    if (expectedDigest === undefined) {
      missingReceipts.push(canonical);
      continue;
    }
    const file = safeProjectFile(root, canonical);
    const actualDigest = file && fs.existsSync(file) && fs.statSync(file).isFile() ? hashFile(file) : '';
    if (actualDigest !== expectedDigest) stale.push(canonical);
  }
  return { ok: stale.length === 0 && missingReceipts.length === 0, stale, missing_receipts: missingReceipts };
}

function validateStagedCandidates(root, stagedAssets) {
  const missing = [];
  const empty = [];
  const invalid = [];
  for (const asset of stagedAssets) {
    const file = safeProjectFile(root, asset.staged);
    if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      missing.push(asset.canonical);
      continue;
    }
    if (!fs.readFileSync(file, 'utf8').trim()) empty.push(asset.canonical);
    if (asset.staged === asset.canonical) invalid.push(asset.canonical);
  }
  return { ok: missing.length === 0 && empty.length === 0 && invalid.length === 0, missing, empty, invalid };
}

function validatePlanningCandidates(root, stagedAssets, acceptedPlan = {}) {
  const byCanonical = new Map(stagedAssets.map(item => [item.canonical, item]));
  const setting = byCanonical.get('设定.md');
  if (setting) {
    const settingFile = safeProjectFile(root, setting.staged);
    const character = analyzeShortCharacterContract(fs.readFileSync(settingFile, 'utf8'));
    if (character.status !== 'pass') {
      return {
        ok: false,
        code: 'short_feedback_character_contract_revision_required',
        planning_target: setting.staged,
        findings: character.findings,
        instruction: '只补齐暂存设定中的人物发动机、主要压力角色和关系债；不要改 Brief 或正文。',
      };
    }
  }
  const outline = byCanonical.get('小节大纲.md');
  if (outline) {
    const outlineFile = safeProjectFile(root, outline.staged);
    const settingFile = setting
      ? safeProjectFile(root, setting.staged)
      : safeProjectFile(root, '设定.md');
    const state = readShortProjectState(root) || {};
    const outlineText = fs.readFileSync(outlineFile, 'utf8');
    const planned = inferPlannedSections(settingFile && fs.existsSync(settingFile) ? fs.readFileSync(settingFile, 'utf8') : '', state, outlineSections(outlineText));
    const narrative = analyzeShortOutlineNarrativeQuality(outlineText, planned, {
      settingText: settingFile && fs.existsSync(settingFile) ? fs.readFileSync(settingFile, 'utf8') : '',
    });
    if (narrative.status !== 'pass') {
      return {
        ok: false,
        code: 'short_feedback_outline_revision_required',
        planning_target: outline.staged,
        findings: narrative.findings.slice(0, 24),
        instruction: '只修暂存小节大纲中的受影响小节，不要进入 Brief 或正文。',
      };
    }
    const titleBoundary = validateTitleCandidate(root, outlineText, acceptedPlan);
    if (!titleBoundary.ok) {
      return {
        ok: false,
        code: titleBoundary.code,
        planning_target: outline.staged,
        findings: titleBoundary.findings,
        instruction: titleBoundary.instruction,
      };
    }
  }
  return { ok: true };
}

function validateTitleCandidate(root, outlineText, acceptedPlan) {
  const lockFile = safeProjectFile(root, resolveShortStateRelative(root, 'section-title-lock.json'));
  const lock = lockFile ? readJson(lockFile) || {} : {};
  if (String(lock.status || '') !== 'confirmed') return { ok: true };
  const candidateTitles = parseOutlineTitles(outlineText);
  const confirmedTitles = normalizeTitleEntries(lock.sections);
  if (candidateTitles.length && sameTitleEntries(candidateTitles, confirmedTitles)) return { ok: true };
  const acceptedTitles = normalizeTitleEntries((acceptedPlan || {}).section_titles);
  if (candidateTitles.length && acceptedTitles.length && sameTitleEntries(candidateTitles, acceptedTitles)) return { ok: true };
  return {
    ok: false,
    code: 'feedback_title_confirmation_required',
    findings: [{
      code: 'section_title_change_not_confirmed',
      current_titles: candidateTitles,
      confirmed_titles: confirmedTitles,
      accepted_titles: acceptedTitles,
    }],
    instruction: '暂存大纲改变了已确认的小节标题；先在方案对话中列出完整新标题并由作者确认，再回写规划。',
  };
}

function projectCanonicalPlanningState(root, task, expectedAssets) {
  try {
    const titleSource = expectedAssets.includes('设定.md') ? '设定.md' : expectedAssets[0];
    const title = inferProjectTitle(fs.readFileSync(safeProjectFile(root, titleSource), 'utf8'), task, root);
    const projectState = expectedAssets.includes('小节大纲.md')
      ? advanceShortPlanRevision(root, { workflowId: String(task.workflow_id || ''), title, outlinePath: '小节大纲.md' })
      : ensureShortProjectState(root, { workflowId: String(task.workflow_id || ''), title, stageId: 'feedback_apply_patch', artifactPath: titleSource });
    const characterMemory = expectedAssets.includes('设定.md')
      ? projectShortCharacterMemory(root, { workflowId: String(task.workflow_id || '') })
      : { status: 'not_applicable' };
    if (String(characterMemory.status || '') === 'blocked_character_contract'
      || String(characterMemory.status || '') === 'blocked_character_setting_missing') {
      return { ok: false, code: 'short_character_memory_projection_blocked', detail: JSON.stringify(characterMemory) };
    }
    const titleLock = expectedAssets.includes('小节大纲.md')
      ? carryForwardConfirmedTitleLock(root, task, projectState)
      : { status: 'not_applicable' };
    if (!titleLock.ok) {
      return { ok: false, code: titleLock.code, detail: JSON.stringify(titleLock) };
    }
    return {
      ok: true,
      project_state: projectState,
      character_memory: characterMemory,
      title_lock: titleLock,
    };
  } catch (error) {
    return { ok: false, code: 'short_project_state_projection_blocked', detail: String((error && error.message) || error) };
  }
}

// A confirmed title list belongs to an exact outline revision. Planning
// feedback may change scene constraints without changing any title. In that
// narrow case, preserve the author's earlier confirmation by rebinding the
// same list to the new digest. Any title addition, deletion, rename, or
// unconfirmed/missing lock remains a hard stop: it needs a separate author
// confirmation and must never be silently accepted by a planning transaction.
function carryForwardConfirmedTitleLock(root, task, projectState) {
  const outlineFile = safeProjectFile(root, '小节大纲.md');
  const lockRel = resolveShortStateRelative(root, 'section-title-lock.json', { forWrite: true });
  const lockFile = safeProjectFile(root, lockRel);
  if (!outlineFile || !lockFile || !fs.existsSync(outlineFile)) {
    return { ok: false, code: 'feedback_title_lock_projection_missing' };
  }
  const lock = readJson(lockFile) || {};
  const nextTitles = parseOutlineTitles(fs.readFileSync(outlineFile, 'utf8'));
  const confirmedTitles = normalizeTitleEntries(lock.sections);
  if (String(lock.status || '') !== 'confirmed') {
    return { ok: true, status: 'not_bound' };
  }
  const acceptedTitles = normalizeTitleEntries(((task.accepted_plan || {}).section_titles));
  const titlesUnchanged = nextTitles.length > 0 && sameTitleEntries(nextTitles, confirmedTitles);
  const titlesExplicitlyAccepted = nextTitles.length > 0
    && acceptedTitles.length > 0
    && sameTitleEntries(nextTitles, acceptedTitles);
  if (!titlesUnchanged && !titlesExplicitlyAccepted) {
    return {
      ok: false,
      code: 'feedback_title_confirmation_required',
      current_titles: nextTitles,
      confirmed_titles: confirmedTitles,
    };
  }
  const sourceDigest = hashFile(outlineFile).replace(/^sha256:/u, '');
  atomicWriteJson(lockFile, {
    ...lock,
    schema_version: String(lock.schema_version || '1.0.0'),
    status: 'confirmed',
    workflow_id: String(task.workflow_id || ''),
    project_id: String(projectState.project_id || ''),
    plan_revision: Number(projectState.plan_revision || 0),
    planned_sections: Number(projectState.planned_sections || nextTitles.length),
    source_outline: '小节大纲.md',
    source_digest: sourceDigest,
    sections: nextTitles.map(item => ({
      ...item,
      confirmed: true,
      title_source: titlesUnchanged ? 'user_confirmed_outline' : 'user_confirmed_feedback_plan',
    })),
    confirmation_basis: titlesUnchanged
      ? 'unchanged_titles_carried_forward'
      : 'feedback_plan_title_confirmation',
    carried_forward_at: new Date().toISOString(),
  });
  return {
    ok: true,
    status: 'carried_forward',
    lock_path: lockRel,
    plan_revision: Number(projectState.plan_revision || 0),
  };
}

function parseOutlineTitles(text) {
  const rows = [];
  for (const line of String(text || '').split(/\r?\n/u)) {
    const match = line.trim().match(/^#{2,4}\s*第\s*0*(\d+)\s*节(?:\s*[:：·｜-]\s*(.*))?$/u);
    if (!match) continue;
    const sectionIndex = Number(match[1]);
    if (!Number.isInteger(sectionIndex) || sectionIndex < 1) continue;
    rows.push({ section_index: sectionIndex, title: String(match[2] || '').trim() });
  }
  return normalizeTitleEntries(rows);
}

function normalizeTitleEntries(value) {
  return (Array.isArray(value) ? value : [])
    .map(item => ({
      section_index: Number((item || {}).section_index),
      title: String((item || {}).title || '').trim().replace(/\s+/gu, ' '),
    }))
    .filter(item => Number.isInteger(item.section_index) && item.section_index > 0)
    .sort((left, right) => left.section_index - right.section_index);
}

function sameTitleEntries(left, right) {
  return left.length === right.length
    && left.every((item, index) => item.section_index === right[index].section_index && item.title === right[index].title);
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function findReusableCommit(root, task, expectedAssets) {
  const dir = path.join(root, '追踪', 'story-system', 'commits');
  if (!fs.existsSync(dir)) return null;
  const expected = normalizeAssets(expectedAssets);
  const stageAttempt = String((((task || {}).stage_execution || {}).stage_attempt_id) || '');
  for (const name of fs.readdirSync(dir).filter(item => item.endsWith('.json')).sort().reverse()) {
    const commit = readCommitFile(path.join(dir, name));
    if (!commit || commit.status !== 'accepted'
      || String(commit.workflow_id || '') !== String(task.workflow_id || '')
      || String(((commit.provenance || {}).stage_attempt_id) || '') !== stageAttempt) continue;
    const actual = normalizeAssets((Array.isArray(commit.artifacts) ? commit.artifacts : []).map(item => item.target));
    if (!validateExpectedAssetSet(expected, actual).ok) continue;
    const artifacts = transactionArtifacts(commit, expected);
    if (artifacts.some(item => {
      const file = safeProjectFile(root, item.canonical);
      return !file || !fs.existsSync(file) || hashFile(file) !== item.after_sha256;
    })) continue;
    return { ...commit, commit_file: path.join(dir, name) };
  }
  return null;
}

function readCommit(root, commitId) {
  const file = path.join(root, '追踪', 'story-system', 'commits', `${String(commitId || '')}.json`);
  const commit = readCommitFile(file);
  if (!commit || commit.status !== 'accepted') throw new Error('feedback_planning_commit_receipt_missing');
  return { ...commit, commit_file: file };
}

function readCommitFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function transactionArtifacts(commit, expectedAssets) {
  const rows = Array.isArray((commit || {}).artifacts) ? commit.artifacts : [];
  return normalizeAssets(expectedAssets).map(canonical => {
    const row = rows.find(item => normalizeAsset((item || {}).target) === canonical) || {};
    return {
      canonical,
      before_sha256: String(row.before_hash || ''),
      after_sha256: String(row.after_hash || row.content_hash || ''),
    };
  });
}

function normalizeStagedAssets(value) {
  const byCanonical = new Map();
  for (const item of Array.isArray(value) ? value : []) {
    const canonical = normalizeAsset((item || {}).canonical);
    const staged = normalizeRelative((item || {}).staged);
    if (!canonical || !staged || byCanonical.has(canonical)) continue;
    byCanonical.set(canonical, { canonical, staged });
  }
  return [...byCanonical.values()].sort((left, right) => left.canonical.localeCompare(right.canonical));
}

function normalizeAssets(value) {
  return [...new Set((Array.isArray(value) ? value : []).map(normalizeAsset).filter(Boolean))].sort();
}

function normalizeAsset(value) {
  const relative = normalizeRelative(value);
  return PLANNING_ASSETS.has(relative) ? relative : '';
}

function normalizeRelative(value) {
  const relative = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//u, '');
  return !relative || relative.startsWith('/') || relative.split('/').includes('..') ? '' : relative;
}

function normalizeSections(value) {
  return [...new Set((Array.isArray(value) ? value : []).map(Number).filter(item => Number.isInteger(item) && item > 0))].sort((left, right) => left - right);
}

function blocked(stageId, code, extra = {}) {
  return stageResult({ kind: 'blocked', code, stage_id: stageId, failure_family: code, ...extra });
}

function retryable(stageId, code, extra = {}) {
  return stageResult({ kind: 'retryable_internal', code, stage_id: stageId, ...extra });
}

module.exports = { finalizeFeedbackPlanningPatch, validateExpectedAssetSet };
