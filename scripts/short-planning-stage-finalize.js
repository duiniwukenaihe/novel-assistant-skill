#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, prepareTransaction } = require('./lib/chapter-commit-store');
const { classifyWorkflowApply, recoverableStageResult, stageRecoveryPresentation } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const {
  advanceShortPlanRevision,
  assertShortProjectOwnership,
  ensureShortProjectState,
  readShortProjectState,
} = require('./lib/short-project-state');
const { appendIntegrationEvent } = require('./lib/integration-outbox');
const {
  analyzeShortOutlineNarrativeQuality,
  inferPlannedSections,
  outlineSections,
} = require('./lib/short-plan-contract');

const STAGE_TARGETS = Object.freeze({
  project_seed: '素材卡.md',
  material_card: '素材卡.md',
  short_setting: '设定.md',
  platform_genre_lock: '设定.md',
  rhythm_pattern_selection: '设定.md',
  section_outline: '小节大纲.md',
});

const STAGE_NUMBERS = Object.freeze({
  project_seed: 1,
  material_card: 1,
  short_setting: 2,
  platform_genre_lock: 3,
  rhythm_pattern_selection: 4,
  section_outline: 5,
});

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
  if (stageId === 'feedback_apply_patch') {
    return runFeedbackPlanningPatch({ root, workflowId, task, execution, args });
  }
  const canonicalTarget = STAGE_TARGETS[stageId] || '';
  if (!canonicalTarget || String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_action_not_applicable', expected: Object.keys(STAGE_TARGETS), actual: stageId, instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  if (String(execution.planning_canonical_target || '') !== canonicalTarget) {
    return finish({ status: 'short_planning_target_mismatch', expected: canonicalTarget, actual: String(execution.planning_canonical_target || ''), instruction: '重新启动当前规划阶段，恢复受控暂存目标。' }, 0, args.json);
  }
  const stagedRel = String(execution.planning_target || '');
  const stagedFile = safeProjectFile(root, stagedRel);
  if (!stagedFile || !fs.existsSync(stagedFile) || !fs.statSync(stagedFile).isFile()) {
    return finish({ status: 'short_planning_staged_artifact_missing', planning_target: stagedRel, instruction: '重新启动当前阶段生成暂存制品；不得直接写正式文件。' }, 0, args.json);
  }
  if (!fs.readFileSync(stagedFile, 'utf8').trim()) {
    return finish({ status: 'short_planning_staged_artifact_empty', planning_target: stagedRel, instruction: '补全当前规划制品后重跑同一 execution_command。' }, 0, args.json);
  }
  if (stageId === 'section_outline') {
    const outlineText = fs.readFileSync(stagedFile, 'utf8');
    const settingText = readText(path.join(root, '设定.md'));
    const currentState = readShortProjectState(root) || {};
    const sections = outlineSections(outlineText);
    const plannedSections = inferPlannedSections(settingText, currentState, sections);
    const narrative = analyzeShortOutlineNarrativeQuality(outlineText, plannedSections);
    if (narrative.status !== 'pass') {
      return finish({
        status: 'short_outline_narrative_revision_required',
        planning_target: stagedRel,
        planned_sections: plannedSections,
        section_roles: narrative.section_roles,
        findings: narrative.findings.slice(0, 24),
        instruction: '只修当前暂存小节大纲：补足可见阻力、场景动作、主角选择、本节兑现、关系变化和代价；高潮必须兑现核心承诺，结尾必须落责任与后果。不得进入 Brief 或正文临场补剧情。',
      }, 0, args.json);
    }
  }
  const pollution = runJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
  const findings = Array.isArray(pollution.findings) ? pollution.findings : [];
  if (findings.length) {
    return finish({
      status: 'short_planning_revision_required',
      planning_target: stagedRel,
      findings: findings.slice(0, 12),
      instruction: '只修当前暂存制品中的重复、工程词泄漏或模型污染，完成后重跑同一 execution_command。',
    }, 0, args.json);
  }
  if (!args.apply) return finish({ status: 'short_planning_ready', stage_id: stageId, planning_target: stagedRel, canonical_target: canonicalTarget }, 0, args.json);

  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '当前目录已有未完成的短篇写作任务；请从任务收件箱恢复或明确结束旧任务。' }, 0, args.json);
  }
  const manifestRel = `${task.task_dir}/artifacts/planning-commits/${stageId}-${safeSegment(execution.stage_attempt_id || 'attempt')}.manifest.json`;
  const manifestFile = safeProjectFile(root, manifestRel);
  atomicWriteJson(manifestFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: '短篇规划',
    chapter: STAGE_NUMBERS[stageId],
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: [{ role: stageId, required: true, staged: stagedRel, target: canonicalTarget }],
    facts: [],
  });
  let commit;
  try {
    const prepared = prepareTransaction(root, manifestRel);
    commit = acceptTransaction(root, prepared.transaction_id);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_planning_commit_blocked'), detail: String(error.message || error), instruction: '暂存制品仍保留；修复提交条件后重跑同一 execution_command，不要重新生成内容。' }, 0, args.json);
  }

  let projectState;
  try {
    const title = inferProjectTitle(fs.readFileSync(path.join(root, canonicalTarget), 'utf8'), task, root);
    projectState = stageId === 'section_outline'
      ? advanceShortPlanRevision(root, { workflowId, title, outlinePath: canonicalTarget })
      : ensureShortProjectState(root, { workflowId, title, stageId, artifactPath: canonicalTarget });
  } catch (error) {
    return finish({
      status: String(error.status || error.code || 'short_project_state_projection_blocked'),
      workflow_id: workflowId,
      canonical_target: canonicalTarget,
      commit_id: String(commit.commit_id || ''),
      instruction: '规划制品已安全提交，但项目状态投影失败；修复状态后重放当前阶段，不要重新生成规划内容。',
    }, 0, args.json);
  }
  const eventType = planningEventType(stageId);
  let integrationEvent = null;
  if (eventType) {
    try {
      integrationEvent = appendIntegrationEvent(root, {
        event_type: eventType,
        workflow_id: workflowId,
        project_id: projectState.project_id,
        project_title: projectState.project_title,
        artifact_path: canonicalTarget,
        artifact_digest: hashFile(path.join(root, canonicalTarget)),
        summary: `${canonicalTarget} 已通过短篇规划事务接受。`,
        tags: ['short_write', stageId],
      });
    } catch (error) {
      integrationEvent = { status: 'deferred', message: String(error.message || error) };
    }
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
    outputs: [canonicalTarget],
    changed_files: [canonicalTarget, '追踪/private-short-extension/project-state.json', ...(integrationEvent && integrationEvent.status === 'appended' ? ['追踪/integration/outbox.jsonl'] : [])],
    created_files: [],
    evidence: [{ planning_target: stagedRel, canonical_target: canonicalTarget, commit_id: String(commit.commit_id || ''), projection_status: String(((commit.projection || {}).status) || ''), project_id: projectState.project_id, plan_revision: projectState.plan_revision, integration_event: integrationEvent ? integrationEvent.status : 'not_applicable' }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: stageId, completed_range: `${canonicalTarget} 已受控接受`, remaining_range: '进入下一规划阶段', resume_from: '' },
    next_recommendation: '进入工作流给出的下一阶段。',
    handoff_summary: `${canonicalTarget} 已通过受控事务写入。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  const result = outcome.result;
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: stageId,
    canonical_target: canonicalTarget,
    commit_id: String(commit.commit_id || ''),
    project_id: String(projectState.project_id || ''),
    plan_revision: Number(projectState.plan_revision || 0),
    integration_event: integrationEvent,
    result_packet: packetRel,
    next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: result }),
  }, outcome.exitCode, args.json);
}

function runFeedbackPlanningPatch({ root, workflowId, task, execution, args }) {
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'feedback_apply_patch') {
    return finish({ status: 'stage_action_not_applicable', actual: String(task.current_stage || ''), instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
  const expectedAssets = normalizePlanningAssets((((acceptedPlan || {}).projection_plan || {}).planning_assets));
  const targets = Array.isArray(execution.planning_targets) ? execution.planning_targets
    .map(item => ({ canonical: normalizePlanningAsset((item || {}).canonical), staged: String((item || {}).staged || '') }))
    .filter(item => item.canonical && item.staged) : [];
  const actualAssets = targets.map(item => item.canonical).sort();
  if (!String(acceptedPlan.plan_id || '') || !expectedAssets.length || JSON.stringify(actualAssets) !== JSON.stringify(expectedAssets.slice().sort())) {
    return finish({
      status: 'short_feedback_planning_scope_mismatch',
      expected_assets: expectedAssets,
      actual_assets: actualAssets,
      instruction: '重新启动反馈回写阶段，从已确认方案重建受控暂存目标；不得手改工作流状态。',
    }, 0, args.json);
  }
  const missing = [];
  const empty = [];
  const pollutionFindings = [];
  for (const target of targets) {
    const stagedFile = safeProjectFile(root, target.staged);
    if (!stagedFile || !fs.existsSync(stagedFile) || !fs.statSync(stagedFile).isFile()) {
      missing.push(target.staged);
      continue;
    }
    if (!fs.readFileSync(stagedFile, 'utf8').trim()) empty.push(target.staged);
    const pollution = runJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
    for (const finding of Array.isArray(pollution.findings) ? pollution.findings : []) {
      pollutionFindings.push({ target: target.staged, ...finding });
    }
    if (target.canonical === '小节大纲.md') {
      const outlineText = fs.readFileSync(stagedFile, 'utf8');
      const settingTarget = targets.find(item => item.canonical === '设定.md');
      const settingFile = settingTarget ? safeProjectFile(root, settingTarget.staged) : path.join(root, '设定.md');
      const currentState = readShortProjectState(root) || {};
      const sections = outlineSections(outlineText);
      const plannedSections = inferPlannedSections(readText(settingFile), currentState, sections);
      const narrative = analyzeShortOutlineNarrativeQuality(outlineText, plannedSections);
      if (narrative.status !== 'pass') {
        const instruction = '只修暂存小节大纲中受影响小节的重复版本、场景行动、可见阻力、人物选择、关系变化、兑现和承接；不要进入写作提要或正文。修完后重新运行当前阶段提交命令。';
        return finish({
          status: 'short_feedback_outline_revision_required',
          planning_target: target.staged,
          planned_sections: plannedSections,
          section_roles: narrative.section_roles,
          findings: narrative.findings.slice(0, 24),
          instruction,
          ...stageRecoveryPresentation(task, { status: 'short_feedback_outline_revision_required', instruction }),
        }, 0, args.json);
      }
    }
  }
  if (missing.length || empty.length) {
    return finish(recoverableStageResult(task, 'short_feedback_planning_artifact_incomplete', '补齐当前暂存规划资产后重跑同一阶段提交命令。', { missing, empty }), 0, args.json);
  }
  if (pollutionFindings.length) {
    return finish(recoverableStageResult(task, 'short_feedback_planning_revision_required', '只修暂存规划资产中的重复、工程词泄漏或模型污染，再重跑同一阶段提交命令。', { findings: pollutionFindings.slice(0, 16) }), 0, args.json);
  }
  if (!args.apply) return finish({ status: 'short_feedback_planning_ready', plan_id: acceptedPlan.plan_id, planning_targets: targets }, 0, args.json);

  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '从任务收件箱恢复当前短篇任务，不要新建第二个写作任务。' }, 0, args.json);
  }
  const affectedSections = normalizeSectionList(acceptedPlan.affected_sections);
  const projectionPlan = acceptedPlan.projection_plan || {};
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/feedback_apply_patch.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const existingPacket = readJson(packetFile);
  const reusableCommit = reusableFeedbackCommit(root, existingPacket, workflowId, execution, actualAssets);
  if (reusableCommit) {
    const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
    const outcome = classifyWorkflowApply(applied);
    return finish({
      status: outcome.applied ? 'applied' : 'apply_blocked',
      workflow_status: outcome.workflowStatus,
      workflow_id: workflowId,
      stage_id: 'feedback_apply_patch',
      plan_id: acceptedPlan.plan_id,
      planning_assets: actualAssets,
      affected_sections: affectedSections,
      commit_id: reusableCommit.commit_id,
      result_packet: packetRel,
      reused_accepted_result: true,
      next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
      ...outcome.presentation,
      ...(outcome.applied ? {} : { recovery: outcome.result }),
    }, outcome.exitCode, args.json);
  }
  const attempt = safeSegment(execution.stage_attempt_id || 'attempt');
  const manifestRel = `${task.task_dir}/artifacts/planning-commits/feedback_apply_patch-${attempt}.manifest.json`;
  const manifestFile = safeProjectFile(root, manifestRel);
  atomicWriteJson(manifestFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: '短篇规划反馈',
    chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: targets.map(item => ({ role: 'feedback_planning_patch', required: true, staged: item.staged, target: item.canonical })),
    facts: [],
  });
  let commit;
  try {
    const prepared = prepareTransaction(root, manifestRel);
    commit = acceptTransaction(root, prepared.transaction_id);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_feedback_planning_commit_blocked'), detail: String(error.message || error), instruction: '暂存规划资产仍保留；修复提交条件后重跑同一 execution_command，不要重新生成。' }, 0, args.json);
  }

  const title = inferProjectTitle(readText(path.join(root, targets[0].canonical)), task, root);
  let projectState;
  try {
    projectState = actualAssets.includes('小节大纲.md')
      ? advanceShortPlanRevision(root, { workflowId, title, outlinePath: '小节大纲.md' })
      : ensureShortProjectState(root, { workflowId, title, stageId: 'feedback_apply_patch', artifactPath: actualAssets[0] });
  } catch (error) {
    return finish({
      status: String(error.status || error.code || 'short_project_state_projection_blocked'),
      workflow_id: workflowId,
      commit_id: String(commit.commit_id || ''),
      instruction: '规划资产已安全提交但项目状态投影失败；修复状态后重放当前提交，不要重新生成内容。',
    }, 0, args.json);
  }

  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'feedback_apply_patch',
    step_id: 'feedback_apply_patch',
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: actualAssets,
    changed_files: [...actualAssets, '追踪/private-short-extension/project-state.json'],
    changed_assets: actualAssets,
    created_files: [],
    evidence: [{ plan_id: acceptedPlan.plan_id, planning_assets: actualAssets, commit_id: String(commit.commit_id || ''), project_id: projectState.project_id, plan_revision: projectState.plan_revision }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'feedback_apply_patch', completed_range: '已确认方案对应规划资产已受控提交', remaining_range: '按受影响小节重建 Brief 并复检正文', resume_from: '' },
    next_recommendation: '进入工作流给出的受影响小节修订队列。',
    handoff_summary: `已按 ${acceptedPlan.plan_id} 回写 ${actualAssets.join('、')}。`,
    feedback_id: String(acceptedPlan.feedback_id || ''),
    impact_level: String(acceptedPlan.impact_level || 'planning'),
    affected_sections: affectedSections,
    cross_section_impact: affectedSections.length > 1,
    brief_invalidated: true,
    accepted_section: Array.isArray(projectState.accepted_sections) && projectState.accepted_sections.length > 0,
    downstream_impact: {
      invalidate_briefs: Array.isArray(projectionPlan.invalidate_briefs) ? projectionPlan.invalidate_briefs : [],
      recheck_prose: Array.isArray(projectionPlan.recheck_prose) ? projectionPlan.recheck_prose : [],
    },
    chapter_commit: {
      mode: 'transactional',
      accepted_commit_id: String(commit.commit_id || ''),
      commit_file: String(commit.commit_file || ''),
      staged_artifacts: targets.map(item => item.staged),
      projection_status: String(commit.projection_status || 'projection_not_required'),
      projection_debt: String(commit.projection_status || '') === 'projection_failed',
    },
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: 'feedback_apply_patch',
    plan_id: acceptedPlan.plan_id,
    planning_assets: actualAssets,
    affected_sections: affectedSections,
    commit_id: String(commit.commit_id || ''),
    result_packet: packetRel,
    next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function reusableFeedbackCommit(root, packet, workflowId, execution, expectedAssets) {
  if (!packet || packet.step_status !== 'completed' || packet.stage_id !== 'feedback_apply_patch') return null;
  if (String(packet.workflow_id || '') !== String(workflowId || '')) return null;
  const packetAssets = normalizePlanningAssets(packet.changed_assets || packet.outputs);
  if (JSON.stringify(packetAssets.slice().sort()) !== JSON.stringify(expectedAssets.slice().sort())) return null;
  const commitId = String((((packet || {}).chapter_commit || {}).accepted_commit_id)
    || ((((packet || {}).evidence || [])[0] || {}).commit_id)
    || '');
  if (!commitId) return null;
  const commitFile = path.join(root, '追踪', 'story-system', 'commits', `${commitId}.json`);
  const commit = readJson(commitFile);
  if (!commit || commit.status !== 'accepted' || String(commit.workflow_id || '') !== String(workflowId || '')) return null;
  if (String(((commit.provenance || {}).stage_attempt_id) || '') !== String(execution.stage_attempt_id || '')) return null;
  const artifacts = Array.isArray(commit.artifacts) ? commit.artifacts : [];
  for (const target of expectedAssets) {
    const artifact = artifacts.find(item => String((item || {}).target || '') === target);
    const canonical = path.join(root, target);
    if (!artifact || !fs.existsSync(canonical) || String(artifact.after_hash || '') !== hashFile(canonical)) return null;
  }
  return { commit_id: commitId, commit_file: commitFile };
}

function normalizePlanningAssets(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(normalizePlanningAsset).filter(Boolean))];
}

function normalizePlanningAsset(value) {
  const normalized = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
  return /^(?:素材卡|设定|小节大纲)\.md$/u.test(normalized) ? normalized : '';
}

function normalizeSectionList(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(Number).filter(item => Number.isInteger(item) && item > 0))].sort((a, b) => a - b);
}

function runJson(root, script, argv) {
  const run = spawnSync(process.execPath, [path.join(__dirname, script), ...argv], { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  return parseJson(run.stdout) || { status: 'checker_failed', findings: [{ type: script, message: String(run.stderr || '').trim().slice(0, 500) }] };
}
function inferProjectTitle(text, task, root) {
  const source = String(text || '');
  const field = source.match(/^(?:作品名|书名|项目名|标题)\s*[：:]\s*(.+)$/mu);
  if (field && String(field[1] || '').trim()) return String(field[1]).trim();
  const heading = source.match(/^#\s+(.+)$/mu);
  if (heading && !/^(?:素材卡|设定|小节大纲)$/u.test(String(heading[1] || '').trim())) return String(heading[1]).trim();
  const identity = task.project_identity && typeof task.project_identity === 'object' ? task.project_identity : {};
  return String(identity.project_title || identity.title || task.bookTitle || task.scope || path.basename(root));
}
function planningEventType(stageId) {
  if (stageId === 'project_seed' || stageId === 'material_card') return 'material_accepted';
  if (stageId === 'section_outline') return 'outline_accepted';
  if (['short_setting', 'platform_genre_lock', 'rhythm_pattern_selection'].includes(stageId)) return 'setting_accepted';
  return '';
}
function hashFile(file) { return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const value = String(rel || ''); const file = path.resolve(root, value); return value && file !== root && file.startsWith(`${root}${path.sep}`) ? file : ''; }
function safeSegment(value) { return String(value || '').replace(/[^A-Za-z0-9._-]/g, '_'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', apply: false, json: false, help: false }; for (let index = 0; index < argv.length; index += 1) { const arg = argv[index]; if (arg === '--project-root') out.projectRoot = argv[++index] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++index] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-planning-stage-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-planning-stage-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n'); return 0; }

process.exitCode = main();
