'use strict';

// Task 5: Engine-neutral short planning service.
//
// finalizePlanningStage(context) returns a Task 1 StageResult only. It runs the
// REAL plan/character/outline validators and, when context.apply is true, the
// REAL chapter-commit transaction path — it never fakes a receipt. The result
// is engine-neutral: V3 passes it straight to engine.applyStageResult; the V2
// CLI wrapper (scripts/short-planning-stage-finalize.js) translates it back to
// its old JSON shape. The service MUST NOT import V2 orchestration: no entry
// guard, no task inbox, no workflow-state-machine, no interaction renderer.
//
// Retry semantics: the V3 Engine is the single writer that persists a compact
// retry_state ({stage_id, failure_family, count}) for retryable_internal in the
// same state-version commit. This service does NOT accept a caller-injected
// retry count and does NOT create a sidecar file. It reads ONLY the freshly
// reread task's retry_state to decide whether a repeated identical failure
// stays internal (first occurrence) or escalates to a structured, unnumbered
// needs_author_choice (second occurrence of the same stage+family).

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, prepareTransaction, rollbackPreparedTransaction } = require('../chapter-commit-store');
const { atomicWriteJson } = require('../workflow-state-store');
const {
  advanceShortPlanRevision,
  assertShortProjectOwnership,
  ensureShortProjectState,
  readShortProjectState,
  resolveShortProjectTitle,
  resolveShortStateRelative,
} = require('../short-project-state');
const { appendIntegrationEvent } = require('../integration-outbox');
const {
  analyzeShortOutlineNarrativeQuality,
  inferPlannedSections,
  outlineSections,
} = require('../short-plan-contract');
const {
  analyzeShortCharacterContract,
  projectShortCharacterMemory,
} = require('../short-character-contract');
// Task 1 StageResult contract: the single frozen-result constructor and the
// frozen/illegal-kind rules live here. The service MUST NOT reimplement that
// contract (no local stageResult). It builds plain input objects and hands them
// to contracts.stageResult, which freezes them and enforces kind/code/stage_id,
// forbids visible_response, and assigns/validates author-choice options.
const { stageResult } = require('../workflow-v3/contracts');

const STAGE_TARGETS = Object.freeze({
  project_seed: '素材卡.md',
  material_card: '素材卡.md',
  material_positioning: '素材卡.md',
  short_setting: '设定.md',
  setting: '设定.md',
  platform_genre_lock: '设定.md',
  rhythm_pattern_selection: '设定.md',
  section_outline: '小节大纲.md',
});

const STAGE_NUMBERS = Object.freeze({
  project_seed: 1,
  material_card: 1,
  material_positioning: 1,
  short_setting: 2,
  setting: 2,
  platform_genre_lock: 3,
  rhythm_pattern_selection: 4,
  section_outline: 5,
});

// The author-choice menu offered when the same failure family recurs. Options
// are deliberately unnumbered: the Interaction Arbiter assigns stable numbers
// after the Engine persists the pending action. These are generic recovery
// actions, not project-specific ones.
const RETRY_EXHAUSTION_OPTIONS = Object.freeze([
  { action_id: 'inspect_current_state', label: '查看未通过项与已识别内容' },
  { action_id: 'free_text', label: '调整当前规划要求' },
  { action_id: 'retry_stage_contract', label: '重新生成当前暂存规划一次' },
]);

// finalizePlanningStage runs validation against the staged planning artifact and
// returns a Task 1 StageResult. When context.apply is true and validation
// passes, it commits the artifact through the real chapter-commit transaction
// before returning a completed result that carries the durable commit receipt.
// context:
//   projectRoot — absolute project root
//   task        — the freshly reread durable task (V3 task.json or V2 shape);
//                 its retry_state is the ONLY retry input the service consults
//   stageId     — the canonical V3/V2 stage id sitting on the task
//   stagedRel   — relative path of the staged artifact under the project root
//   apply       — when true, commit on success; when false, validate only
function finalizePlanningStage(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = String(context.stageId || task.current_stage || '');
  const canonicalTarget = STAGE_TARGETS[stageId] || '';
  if (!canonicalTarget) {
    return stageResult({
      kind: 'blocked',
      code: 'short_planning_stage_unknown',
      stage_id: stageId,
      failure_family: 'stage_unknown',
      instruction: '未识别的规划阶段；读取当前 execution_command，不要重试旧阶段命令。',
    });
  }
  const stagedRel = String(context.stagedRel || '');
  const stagedFile = safeProjectFile(root, stagedRel);
  if (!stagedFile || !fs.existsSync(stagedFile) || !fs.statSync(stagedFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_planning_staged_artifact_missing',
      stage_id: stageId,
      failure_family: 'staged_artifact_missing',
      planning_target: stagedRel,
      instruction: '重新启动当前阶段生成暂存制品；不得直接写正式文件。',
    });
  }
  if (!fs.readFileSync(stagedFile, 'utf8').trim()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_planning_staged_artifact_empty',
      stage_id: stageId,
      failure_family: 'staged_artifact_empty',
      planning_target: stagedRel,
      instruction: '补全当前规划制品后重跑同一 execution_command。',
    });
  }

  const stagedText = fs.readFileSync(stagedFile, 'utf8');
  const settingText = canonicalTarget === '设定.md'
    ? stagedText
    : readText(path.join(root, '设定.md'));

  // Character contract: enforced on setting-derived stages and on the outline.
  const characterStages = ['short_setting', 'setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline'];
  if (characterStages.includes(stageId)) {
    const characterContract = analyzeShortCharacterContract(settingText);
    if (characterContract.status !== 'pass') {
      return planningFailure(root, task, stageId, stagedRel, {
        family: 'character_contract',
        code: 'short_character_contract_revision_required',
        canonical_target: canonicalTarget === '设定.md' ? stagedRel : '设定.md',
        protagonist: characterContract.protagonist,
        findings: characterContract.findings,
        advisories: characterContract.advisories,
        instruction: '先补齐主角目标、软肋/内在需求、缺陷或误信、能力边界、主动变化，以及主要压力角色的独立利益和人物关系债；不要进入小节大纲、Brief 或正文。',
      });
    }
  }

  // Outline narrative quality: only on the section_outline stage.
  if (stageId === 'section_outline') {
    const outlineText = stagedText;
    const currentState = readShortProjectState(root) || {};
    const sections = outlineSections(outlineText);
    const plannedSections = inferPlannedSections(settingText, currentState, sections);
    const narrative = analyzeShortOutlineNarrativeQuality(outlineText, plannedSections, { settingText });
    if (narrative.status !== 'pass') {
      return planningFailure(root, task, stageId, stagedRel, {
        family: 'outline_narrative',
        code: 'short_outline_narrative_revision_required',
        findings: narrative.findings.slice(0, 24),
        planned_sections: plannedSections,
        section_roles: narrative.section_roles,
        instruction: '只修当前暂存小节大纲中真正缺失的故事功能；沿用自然中文标题与字段，不得新增 YAML、JSON、S00/B01 或其他机器编号。机器结构由确定性脚本自动投影。',
      });
    }
  }

  // Output pollution check: staged artifact must not carry repeated filler,
  // engineering-term leakage, or provider artifacts.
  const pollution = runJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
  const pollutionFindings = Array.isArray(pollution.findings) ? pollution.findings : [];
  if (pollutionFindings.length) {
    return planningFailure(root, task, stageId, stagedRel, {
      family: 'output_pollution',
      code: 'short_planning_revision_required',
      findings: pollutionFindings.slice(0, 12),
      instruction: '只修当前暂存制品中的重复、工程词泄漏或模型污染，完成后重跑同一 execution_command。',
    });
  }

  if (!context.apply) {
    return stageResult({
      kind: 'completed',
      code: 'short_planning_validated',
      stage_id: stageId,
      canonical_target: canonicalTarget,
      planning_target: stagedRel,
      apply_required_for_commit: true,
    });
  }

  return commitPlanningArtifact({
    root,
    task,
    stageId,
    canonicalTarget,
    stagedRel,
    stagedText,
  });
}

// Build a failure StageResult honoring the durable retry_state: the first
// same-family failure on a stage returns retryable_internal (the Engine then
// persists retry_state); a repeated same stage+family failure escalates to a
// structured, unnumbered needs_author_choice so the author decides instead of
// the model looping. The family is the only retry key — a different family
// resets the count and stays internal.
function planningFailure(root, task, stageId, stagedRel, detail) {
  const family = String(detail.family || detail.code || 'planning_failure');
  const previous = task.retry_state && typeof task.retry_state === 'object' ? task.retry_state : null;
  const exhausted = Boolean(previous)
    && String(previous.stage_id || '') === String(stageId || '')
    && String(previous.failure_family || '') === family
    && Number(previous.count || 0) >= 1;

  if (!exhausted) {
    return stageResult({
      kind: 'retryable_internal',
      code: detail.code,
      stage_id: stageId,
      failure_family: family,
      planning_target: stagedRel,
      findings: detail.findings,
      advisories: detail.advisories,
      planned_sections: detail.planned_sections,
      section_roles: detail.section_roles,
      canonical_target: detail.canonical_target,
      instruction: detail.instruction,
    });
  }

  return stageResult({
    kind: 'needs_author_choice',
    code: detail.code,
    stage_id: stageId,
    failure_family: family,
    question: '当前规划已连续未通过同项校验；请选择处理方式，避免模型反复重写浪费 token。',
    options: RETRY_EXHAUSTION_OPTIONS,
    planning_target: stagedRel,
    findings: detail.findings,
    advisories: detail.advisories,
    planned_sections: detail.planned_sections,
    section_roles: detail.section_roles,
    canonical_target: detail.canonical_target,
    instruction: detail.instruction,
  });
}

// Commit the staged planning artifact through the real chapter-commit
// transaction, project-state projection, and integration outbox. The returned
// completed StageResult carries the durable commit receipt as evidence — V3/V2
// callers can prove the artifact was accepted, not faked.
function commitPlanningArtifact({ root, task, stageId, canonicalTarget, stagedRel, stagedText }) {
  const workflowId = String(task.workflow_id || '');
  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return stageResult({
      kind: 'blocked',
      code: String(error.status || error.code || 'short_project_ownership_conflict'),
      stage_id: stageId,
      failure_family: 'project_ownership_conflict',
      workflow_id: workflowId,
      instruction: '当前目录已有未完成的短篇写作任务；请从任务收件箱恢复或明确结束旧任务。',
    });
  }

  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const taskDir = String(task.task_dir || '');
  const attempt = safeSegment(String(execution.stage_attempt_id || 'attempt'));
  const manifestRel = `${taskDir}/artifacts/planning-commits/${stageId}-${attempt}.manifest.json`;
  const manifestFile = safeProjectFile(root, manifestRel);
  if (!manifestFile) {
    return stageResult({
      kind: 'blocked',
      code: 'short_planning_manifest_path_invalid',
      stage_id: stageId,
      failure_family: 'manifest_path_invalid',
      instruction: '任务目录路径不合法；重新显示当前任务，不要手改工作流状态。',
    });
  }
  atomicWriteJson(manifestFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: '短篇规划',
    chapter: Number(STAGE_NUMBERS[stageId] || 0),
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: stageId, required: true, staged: stagedRel, target: canonicalTarget }],
    facts: [],
  });

  let commit;
  let preparedTransactionId = '';
  try {
    rollbackOrphanedPlanningTransactions(root, workflowId, stageId);
    const prepared = prepareTransaction(root, manifestRel);
    preparedTransactionId = String(prepared.transaction_id || '');
    commit = acceptTransaction(root, prepared.transaction_id);
  } catch (error) {
    if (preparedTransactionId) {
      try {
        rollbackPreparedTransaction(root, preparedTransactionId, `planning accept failed: ${String(error.status || error.code || error.message || error)}`);
      } catch (_) {
        // Preserve the original commit error; the next run reconciles the orphan.
      }
    }
    return stageResult({
      kind: 'blocked',
      code: String(error.status || error.code || 'short_planning_commit_blocked'),
      stage_id: stageId,
      failure_family: 'commit_blocked',
      detail: String(error.message || error),
      planning_target: stagedRel,
      instruction: '暂存制品仍保留；修复提交条件后重跑同一 execution_command，不要重新生成内容。',
    });
  }

  let projectState;
  try {
    const title = inferProjectTitle(stagedText, task, root);
    projectState = stageId === 'section_outline'
      ? advanceShortPlanRevision(root, { workflowId, title, outlinePath: canonicalTarget })
      : ensureShortProjectState(root, { workflowId, title, stageId, artifactPath: canonicalTarget });
  } catch (error) {
    return stageResult({
      kind: 'blocked',
      code: String(error.status || error.code || 'short_project_state_projection_blocked'),
      stage_id: stageId,
      failure_family: 'project_state_projection_blocked',
      workflow_id: workflowId,
      canonical_target: canonicalTarget,
      commit_id: String(commit.commit_id || ''),
      instruction: '规划制品已安全提交，但项目状态投影失败；修复状态后重放当前阶段，不要重新生成规划内容。',
    });
  }

  let characterMemory = null;
  if (canonicalTarget === '设定.md') {
    characterMemory = projectShortCharacterMemory(root, { workflowId });
    if (characterMemory.status !== 'projected') {
      return stageResult({
        kind: 'blocked',
        code: 'short_character_memory_projection_blocked',
        stage_id: stageId,
        failure_family: 'character_memory_projection_blocked',
        workflow_id: workflowId,
        canonical_target: canonicalTarget,
        commit_id: String(commit.commit_id || ''),
        character_memory: characterMemory,
        instruction: '设定已安全提交，但人物记忆投影失败；修复人物合同后重放投影，不要重新生成设定。',
      });
    }
  }

  let integrationEvent = null;
  const eventType = planningEventType(stageId);
  if (eventType) {
    try {
      integrationEvent = appendIntegrationEvent(root, {
        event_type: eventType,
        workflow_id: workflowId,
        project_id: projectState.project_id,
        project_title: resolveShortProjectTitle(projectState, path.basename(root)),
        artifact_path: canonicalTarget,
        artifact_digest: hashFile(path.join(root, canonicalTarget)),
        summary: `${canonicalTarget} 已通过短篇规划事务接受。`,
        tags: ['short_write', stageId],
      });
    } catch (error) {
      integrationEvent = { status: 'deferred', message: String(error.message || error) };
    }
  }

  return stageResult({
    kind: 'completed',
    code: 'short_planning_accepted',
    stage_id: stageId,
    canonical_target: canonicalTarget,
    planning_target: stagedRel,
    commit_id: String(commit.commit_id || ''),
    commit_file: String(commit.commit_file || ''),
    projection_status: String(commit.projection_status || 'projection_not_required'),
    project_id: String(projectState.project_id || ''),
    project_title: resolveShortProjectTitle(projectState, path.basename(root)),
    plan_revision: Number(projectState.plan_revision || 0),
    character_memory: characterMemory ? characterMemory.status : 'not_applicable',
    integration_event: integrationEvent,
    staged_artifacts: [stagedRel],
    // No next_stage: the canonical V3 graph (short-graph.nextNode) is the ONLY
    // transition authority. A business service must not claim a different hop.
    // V3 gets the next node from the graph; the V2 wrapper reads it from the
    // apply-result workflow-state-machine outcome, not from this evidence.
  });
}

function planningEventType(stageId) {
  if (stageId === 'project_seed' || stageId === 'material_card' || stageId === 'material_positioning') return 'material_accepted';
  if (stageId === 'section_outline') return 'outline_accepted';
  if (['short_setting', 'setting', 'platform_genre_lock', 'rhythm_pattern_selection'].includes(stageId)) return 'setting_accepted';
  return '';
}

function rollbackOrphanedPlanningTransactions(root, workflowId, stageId) {
  const transactionsRoot = path.join(root, '追踪', 'story-system', 'transactions');
  if (!fs.existsSync(transactionsRoot) || !fs.statSync(transactionsRoot).isDirectory()) return [];
  const rolledBack = [];
  for (const entry of fs.readdirSync(transactionsRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const transactionFile = path.join(transactionsRoot, entry.name, 'transaction.json');
    let transaction;
    try {
      transaction = JSON.parse(fs.readFileSync(transactionFile, 'utf8'));
    } catch (_) {
      continue;
    }
    if (String(transaction.status || '') !== 'prepared') continue;
    if (String(transaction.workflow_id || '') !== String(workflowId || '')) continue;
    if (String(transaction.volume || '') !== '短篇规划') continue;
    if (Number(transaction.chapter || 0) !== Number(STAGE_NUMBERS[stageId] || 0)) continue;
    rollbackPreparedTransaction(root, entry.name, `superseded orphan before retrying ${stageId}`);
    rolledBack.push(entry.name);
  }
  return rolledBack;
}

// inferProjectTitle and the small file/process helpers below are also used by
// the V2 wrapper's feedback_apply_patch orchestration (a different commit
// volume, multiple targets, feedback_id/brief-invalidation — structurally
// distinct from the single-target planning path this service owns). Exporting
// them keeps a single implementation rather than a V2-side duplicate copy; the
// feedback path imports these instead of redefining them.
function inferProjectTitle(text, task, root) {
  const source = String(text || '');
  const field = source.match(/^(?:作品名|书名|项目名|标题)\s*[：:]\s*(.+)$/mu);
  if (field && String(field[1] || '').trim()) return String(field[1]).trim();
  const heading = source.match(/^#\s+(.+)$/mu);
  if (heading && !/^(?:素材卡|设定|小节大纲)$/u.test(String(heading[1] || '').trim())) return String(heading[1]).trim();
  const identity = task.project_identity && typeof task.project_identity === 'object' ? task.project_identity : {};
  return String(identity.project_title || identity.title || task.bookTitle || task.scope || path.basename(root));
}

function runJson(root, script, argv) {
  const run = spawnSync(process.execPath, [path.join(__dirname, '..', '..', script), ...argv], { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  return parseJson(run.stdout) || { status: 'checker_failed', findings: [{ type: script, message: String(run.stderr || '').trim().slice(0, 500) }] };
}

function hashFile(file) { return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`; }
function safeProjectFile(root, rel) {
  const value = String(rel || '');
  if (!value || path.isAbsolute(value) || value.split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, value);
  return value && file !== root && file.startsWith(`${root}${path.sep}`) ? file : '';
}
function safeSegment(value) { return String(value || '').replace(/[^A-Za-z0-9._-]/g, '_'); }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }

module.exports = {
  finalizePlanningStage,
  STAGE_TARGETS,
  STAGE_NUMBERS,
  RETRY_EXHAUSTION_OPTIONS,
  // Shared helpers reused by the V2 wrapper's feedback_apply_patch path so the
  // feedback orchestration does not redefine them. Not part of the StageResult
  // contract; plain utilities with a single implementation.
  inferProjectTitle,
  planningEventType,
  rollbackOrphanedPlanningTransactions,
  hashFile,
  safeSegment,
  safeProjectFile,
  readText,
  runJson,
};
