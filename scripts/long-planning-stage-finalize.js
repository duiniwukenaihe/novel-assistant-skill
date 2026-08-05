#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  acceptTransaction,
  prepareTransaction,
  rollbackPreparedTransaction,
} = require('./lib/chapter-commit-store');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const {
  authoritativePlanningTargets,
  planDigest,
  planningReviewForProducer,
} = require('./lib/long-planning-revision');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const authority = resolveTaskAuthority(root, args.workflowId);
  if (authority.status !== 'ok') return finish(authority, 2, args.json);
  const task = authority.task;

  const alreadyApplied = acceptedPlanningResult(root, task);
  if (alreadyApplied) {
    return finish({
      status: 'long_planning_already_applied',
      workflow_id: task.workflow_id,
      accepted_commit_id: alreadyApplied.accepted_commit_id,
      result_packet: alreadyApplied.result_packet,
      next_stage: String(task.current_stage || ''),
      reused_accepted_result: true,
      host_started: false,
    }, 0, args.json);
  }

  const preflight = validateTask(root, task);
  if (preflight.status !== 'ready') return finish(preflight, 2, args.json);
  if (!args.apply) {
    return finish({
      status: 'long_planning_commit_ready',
      workflow_id: task.workflow_id,
      stage_attempt_id: preflight.stageAttemptId,
      canonical_targets: preflight.canonicalTargets,
      host_execution_mode: preflight.runnerBinding.mode,
      host_started: false,
      instruction: '使用 --apply 执行确定性长篇规划事务提交。',
    }, 0, args.json);
  }
  try {
    // An earlier invocation may have accepted the canonical transaction and
    // then been blocked while applying the workflow result. In that recovery
    // state staged and canonical files are intentionally equal. Reuse the
    // exact accepted commit before applying the normal unchanged-candidate
    // guard, so the durable task can finish without a second commit.
    const acceptedState = acceptedCommitState(root, task, preflight);
    if (acceptedState.status === 'conflict') {
      return finish(block(
        'long_planning_accepted_commit_conflict',
        '当前阶段尝试已有内容不一致的 accepted commit，禁止二次覆盖正式规划资产。',
        { conflicting_commit_ids: acceptedState.commitIds },
      ), 2, args.json);
    }
    const acceptedCommit = acceptedState.status === 'exact' ? acceptedState.commit : null;
    if (!acceptedCommit && preflight.unchangedTargets.length > 0) {
      return finish(block(
        'long_planning_candidate_unchanged',
        '未通过的规划稿仍与正式稿完全相同，不能把无修改候选当作修订完成。',
        { unchanged_targets: preflight.unchangedTargets },
      ), 2, args.json);
    }
    const commit = acceptedCommit || createAcceptedCommit(root, task, preflight);
    const result = buildResultPacket(root, task, preflight, commit);
    atomicWriteJson(safeFile(root, preflight.resultPacketRel), result);
    if (preflight.runnerBinding.mode === 'managed_runner') {
      return finish({
        status: 'long_planning_result_ready',
        workflow_id: task.workflow_id,
        accepted_commit_id: commit.commit_id,
        result_packet: preflight.resultPacketRel,
        reused_accepted_commit: commit.already_accepted === true,
        host_execution_mode: 'managed_runner',
        host_started: false,
      }, 0, args.json);
    }
    const applied = applyResult(root, task, preflight.resultPacketRel);
    if (!applied.applied) {
      return finish({
        status: 'long_planning_apply_blocked',
        workflow_id: task.workflow_id,
        accepted_commit_id: commit.commit_id,
        result_packet: preflight.resultPacketRel,
        workflow_result: applied.result,
        host_started: false,
      }, applied.exitCode || 2, args.json);
    }
    return finish({
      status: 'long_planning_applied',
      workflow_id: task.workflow_id,
      accepted_commit_id: commit.commit_id,
      result_packet: preflight.resultPacketRel,
      canonical_targets: preflight.canonicalTargets,
      reused_accepted_commit: commit.already_accepted === true,
      next_stage: String(applied.result.current_stage || ((applied.result.task || {}).current_stage) || ''),
      host_started: false,
    }, 0, args.json);
  } catch (error) {
    return finish(block(
      String(error.status || error.code || 'long_planning_commit_failed'),
      String(error.message || error),
    ), 2, args.json);
  }
}

function validateTask(root, task) {
  if (String(task.workflow_type || '') !== 'long_write') {
    return block('long_planning_target_mapping_invalid', '当前任务不是长篇写作任务。');
  }
  const execution = task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : {};
  const producerStage = String(task.current_stage || '');
  const reviewStage = planningReviewForProducer(producerStage);
  if (!reviewStage
      || String(execution.stage_id || '') !== producerStage
      || String(execution.status || '') !== 'running') {
    return block('stage_action_not_applicable', `当前不是运行中的长篇规划修订：${task.current_stage || 'unknown'}`);
  }
  const stageAttemptId = String(execution.stage_attempt_id || '');
  const planningAttemptId = String(execution.planning_stage_attempt_id || stageAttemptId);
  if (!stageAttemptId || planningAttemptId !== stageAttemptId) {
    return block('long_planning_stage_attempt_mismatch', '规划候选合同不属于当前阶段尝试。', {
      expected_stage_attempt_id: stageAttemptId,
      actual_stage_attempt_id: planningAttemptId,
    });
  }

  const mapping = validateExactPairs(root, task, execution);
  if (mapping.status !== 'ready') return mapping;
  const resultPacketRel = normalizeRel(execution.expected_result_packet);
  if (!resultPacketRel || !safeFileOrEmpty(root, resultPacketRel)) {
    return block('long_planning_target_mapping_invalid', '当前阶段缺少安全的唯一结果包路径。');
  }
  const runnerBinding = resolveRunnerBinding(root, task, execution);
  if (runnerBinding.status !== 'ready') return runnerBinding;
  return {
    status: 'ready',
    producerStage,
    reviewStage,
    execution,
    stageAttemptId,
    pairs: mapping.pairs,
    canonicalTargets: mapping.pairs.map((item) => item.canonical),
    stagedTargets: mapping.pairs.map((item) => item.staged),
    unchangedTargets: mapping.pairs
      .filter((item) => item.canonicalHash === item.stagedHash)
      .map((item) => item.canonical),
    resultPacketRel,
    runnerBinding,
  };
}

function validateExactPairs(root, task, execution) {
  const pairs = Array.isArray(execution.planning_targets) ? execution.planning_targets : [];
  const canonical = normalizedPathArray(execution.canonical_write_set);
  const staged = normalizedPathArray(execution.write_set);
  const revision = normalizedPathArray(execution.revision_targets);
  const producerStage = String((task || {}).current_stage || '');
  const authority = authoritativePlanningTargets(root, task, producerStage);
  const failed = authority.status === 'ready' ? authority.targets : null;
  const planningRevision = (task || {}).planning_revision || {};
  const revisionPlan = planningRevision.plan && typeof planningRevision.plan === 'object' ? planningRevision.plan : null;
  if (['master_outline', 'volume_outline'].includes(producerStage)
      && (!revisionPlan
        || String(planningRevision.status || '') !== 'accepted_for_execution'
        || planDigest(revisionPlan) !== String(planningRevision.accepted_plan_digest || '')
        || String(execution.planning_revision_digest || '') !== String(planningRevision.accepted_plan_digest || ''))) {
    return block('long_planning_target_mapping_invalid', '当前规划修订没有绑定作者已确认的方案摘要。');
  }
  if (!pairs.length || !canonical || !staged || !revision || !failed
      || canonical.length !== pairs.length || staged.length !== pairs.length
      || revision.length !== pairs.length || failed.length !== pairs.length
      || hasDuplicates(canonical) || hasDuplicates(staged)) {
    return block('long_planning_target_mapping_invalid', '长篇规划暂存稿与正式目标数量或唯一性不一致。');
  }
  const validated = [];
  for (let index = 0; index < pairs.length; index += 1) {
    const pair = pairs[index] && typeof pairs[index] === 'object' ? pairs[index] : {};
    const canonicalRel = normalizeRel(pair.canonical);
    const stagedRel = normalizeRel(pair.staged);
    if (!canonicalRel || !stagedRel
        || canonicalRel !== canonical[index]
        || canonicalRel !== revision[index]
        || canonicalRel !== failed[index]
        || stagedRel !== staged[index]
        || !stagedRel.startsWith('追踪/workflow/staging/')
        || !canonicalMatchesProducer(canonicalRel, producerStage)) {
      return block('long_planning_target_mapping_invalid', '长篇规划目标映射与冻结的失败目标不一致。', { index });
    }
    const canonicalFile = safeRegularFile(root, canonicalRel);
    if (!canonicalFile) {
      return block('long_planning_target_mapping_invalid', `正式规划资产不存在或路径不安全：${canonicalRel}`);
    }
    const stagedFile = safeRegularFile(root, stagedRel);
    if (!stagedFile) {
      return block('long_planning_staged_artifact_missing', `暂存规划资产不存在、为空或路径不安全：${stagedRel}`, {
        staged_target: stagedRel,
      });
    }
    validated.push({
      canonical: canonicalRel,
      staged: stagedRel,
      canonicalFile,
      stagedFile,
      canonicalHash: hashFile(canonicalFile),
      stagedHash: hashFile(stagedFile),
    });
  }
  return { status: 'ready', pairs: validated };
}

function resolveRunnerBinding(root, task, execution) {
  const guard = task.runtime_guard || {};
  const active = guard.runner_lease || {};
  const last = guard.last_runner_attempt || {};
  const producerStage = String((task || {}).current_stage || '');
  const expectedResult = String(execution.expected_result_packet || '');
  const relevant = (candidate) => String((candidate || {}).stage_id || '') === producerStage
    && String((candidate || {}).expected_result_packet || '') === expectedResult;
  const activePresent = Object.keys(active).length > 0;
  const binding = activePresent ? active : relevant(last) ? last : null;
  if (!binding) return { status: 'ready', mode: 'deterministic_command', runnerPacketRel: '' };
  if (binding === active) {
    const expiresAt = Date.parse(String(active.expires_at || ''));
    if (!String(active.run_id || '') || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      return block('long_planning_runner_binding_invalid', '活动 runner lease 已过期或缺少运行身份。');
    }
  }
  const executionAttempt = String(execution.stage_attempt_id || '');
  const executionWorkUnit = String(execution.work_unit_id || '');
  if (String(binding.stage_id || '') !== producerStage
      || String(binding.expected_result_packet || '') !== expectedResult
      || !String(binding.run_id || '')
      || !String(binding.stage_attempt_id || '')
      || String(binding.stage_attempt_id || '') !== executionAttempt
      || !executionWorkUnit
      || String(binding.work_unit_id || '') !== executionWorkUnit) {
    return block('long_planning_runner_binding_invalid', '托管 runner attempt 与当前规划阶段尝试不一致。');
  }
  const runnerPacketRel = normalizeRel(binding.runner_packet_path);
  const runnerFile = safeFileOrEmpty(root, runnerPacketRel);
  if (!runnerPacketRel || !runnerFile || !fs.existsSync(runnerFile) || !fs.statSync(runnerFile).isFile()) {
    return block('long_planning_runner_binding_invalid', '托管 runner 已绑定，但 runner packet 不存在或路径不安全。');
  }
  const runner = readJson(runnerFile);
  if (!runner
      || String(runner.workflow_id || '') !== String(task.workflow_id || '')
      || String(runner.stage_id || '') !== producerStage
      || String(runner.expected_result_packet || '') !== String(execution.expected_result_packet || '')
      || String(runner.run_id || '') !== String(binding.run_id || '')
      || String(runner.stage_attempt_id || '') !== executionAttempt
      || String(runner.work_unit_id || '') !== String(execution.work_unit_id || '')) {
    return block('long_planning_runner_binding_invalid', '托管 runner packet 与当前阶段合同不一致。');
  }
  return { status: 'ready', mode: 'managed_runner', runnerPacketRel, runner };
}

function acceptedCommitState(root, task, preflight) {
  const dir = path.join(root, '追踪', 'story-system', 'commits');
  if (!fs.existsSync(dir)) return { status: 'none', commit: null, commitIds: [] };
  const expectedTargets = preflight.canonicalTargets;
  const matching = [];
  const conflicts = [];
  for (const name of fs.readdirSync(dir).filter((item) => item.endsWith('.json')).sort().reverse()) {
    const file = path.join(dir, name);
    const commit = readJson(file);
    if (!commit || commit.status !== 'accepted'
        || String(commit.workflow_id || '') !== String(task.workflow_id || '')
        || String(((commit.provenance || {}).stage_attempt_id) || '') !== preflight.stageAttemptId) continue;
    const artifacts = Array.isArray(commit.artifacts) ? commit.artifacts : [];
    const targets = artifacts.map((item) => normalizeRel((item || {}).target));
    if (!sameArray(targets, expectedTargets)) continue;
    const hashesMatch = artifacts.length === preflight.pairs.length && artifacts.every((artifact, index) => {
      const expected = String((artifact || {}).after_hash || '').toLowerCase();
      return expected === preflight.pairs[index].stagedHash.toLowerCase()
        && expected === preflight.pairs[index].canonicalHash.toLowerCase();
    });
    if (!hashesMatch || !String(commit.transaction_id || '')) {
      conflicts.push(String(commit.commit_id || name));
      continue;
    }
    matching.push(commit);
  }
  if (conflicts.length > 0) return { status: 'conflict', commit: null, commitIds: conflicts };
  if (matching.length === 0) return { status: 'none', commit: null, commitIds: [] };
  return { status: 'exact', commit: acceptTransaction(root, matching[0].transaction_id), commitIds: [] };
}

function createAcceptedCommit(root, task, preflight) {
  const attempt = safeSegment(preflight.stageAttemptId);
  const manifestRel = `${task.task_dir}/audit/long-planning-commit-manifests/${attempt}.json`;
  atomicWriteJson(safeFile(root, manifestRel), {
    schemaVersion: '1.0.0',
    workflow_id: task.workflow_id,
    volume: '长篇规划',
    chapter: stableAttemptNumber(preflight.stageAttemptId),
    provenance: {
      task_family_id: String(task.task_family_id || ''),
      workflow_id: String(task.workflow_id || ''),
      branch_id: String(task.branch_id || task.workflow_id || ''),
      stage_attempt_id: preflight.stageAttemptId,
      acceptance_status: 'accepted',
    },
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: preflight.pairs.map((item) => ({
      role: preflight.producerStage,
      required: true,
      staged: item.staged,
      target: item.canonical,
    })),
    facts: [],
    promise_deltas: [],
  });
  let prepared = null;
  try {
    prepared = prepareTransaction(root, manifestRel);
    return acceptTransaction(root, prepared.transaction_id);
  } catch (error) {
    if (prepared && prepared.transaction_id) {
      try { rollbackPreparedTransaction(root, prepared.transaction_id, 'long planning commit failed'); } catch (_) { /* already rolled back */ }
    }
    const wrapped = failure('long_planning_commit_failed', String(error.message || error));
    wrapped.cause_status = String(error.status || error.code || '');
    throw wrapped;
  }
}

function buildResultPacket(root, task, preflight, commit) {
  const execution = preflight.execution;
  const runner = preflight.runnerBinding;
  const memoryReceipt = runner.mode === 'managed_runner'
    ? ((((runner.runner || {}).memory_context || {}).memory_read_receipt) || ((execution.memory_context || {}).memory_read_receipt) || null)
    : (((execution.memory_context || {}).memory_read_receipt) || null);
  return {
    schemaVersion: '1.0.0',
    workflow_id: task.workflow_id,
    workflow_type: 'long_write',
    stage_id: preflight.producerStage,
    step_id: String(execution.step_id || preflight.producerStage),
    stage_attempt_id: preflight.stageAttemptId,
    work_unit_id: String(execution.work_unit_id || ''),
    owner_module: String(execution.owner_module || 'story-long-write'),
    lifecycle_node: String(execution.lifecycle_node || preflight.producerStage),
    asset_target: execution.asset_target && typeof execution.asset_target === 'object'
      ? execution.asset_target
      : { kind: 'planning_asset', id: preflight.producerStage },
    review_requirement: execution.review_requirement && typeof execution.review_requirement === 'object'
      ? execution.review_requirement
      : { required: false, failure_return: '' },
    step_status: 'completed',
    outputs: preflight.pairs.map((item) => ({ kind: preflight.producerStage, path: item.canonical, sha256: item.stagedHash })),
    changed_files: preflight.canonicalTargets,
    evidence: [{
      type: 'accepted_long_planning_transaction',
      commit_id: commit.commit_id,
      canonical_targets: preflight.canonicalTargets,
    }],
    verification_result: 'pass',
    blocking_reason: '',
    next_recommendation: `进入 ${preflight.reviewStage}。`,
    handoff_summary: '未通过的长篇规划资产已通过一次原子事务完成修订。',
    checkpoint_state: { stage_id: preflight.producerStage },
    output_health_result: 'pass',
    memory_updates: [],
    memory_update_omission_reason: '本次只修订已存在的规划资产，不产生新的已确认作品记忆。',
    result_packet_path: preflight.resultPacketRel,
    host_execution_mode: runner.mode,
    runner_packet_path: runner.mode === 'managed_runner' ? runner.runnerPacketRel : '',
    memory_read_receipt: memoryReceipt,
    asset_revision: { status: 'verified', asset_id: String(((execution.asset_target || {}).id) || 'current-story-stage') },
    review_decision: 'not_applicable',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'advance', target: preflight.producerStage },
    next_stage_id: preflight.reviewStage,
    result_write_set: preflight.canonicalTargets,
    chapter_commit: {
      mode: 'transactional',
      accepted_commit_id: commit.commit_id,
      commit_file: relativePosix(root, String(commit.commit_file || '')),
      projection_status: commit.projection_status,
      projection_debt: commit.projection_status === 'projection_failed',
      staged_artifacts: preflight.stagedTargets,
    },
  };
}

function acceptedPlanningResult(root, task) {
  const producerStages = Object.keys({ master_outline: 1, volume_outline: 1, stage_detail_outline: 1 });
  const currentStage = String(task.current_stage || '');
  if (producerStages.includes(currentStage)) return null;
  const currentHistory = task.result_history && typeof task.result_history === 'object'
    && producerStages.includes(String(task.result_history.stage_id || ''))
    ? normalizeRel(task.result_history.path)
    : '';
  const attempt = currentHistory ? null : (Array.isArray(task.stage_attempt_history) ? task.stage_attempt_history : [])
    .slice().reverse()
    .find((item) => producerStages.includes(String((item || {}).stage_id || ''))
      && String((item || {}).status || '') === 'completed'
      && String((item || {}).accepted_result_packet || ''));
  const resultPacket = currentHistory || normalizeRel((attempt || {}).accepted_result_packet);
  if (!resultPacket) return null;
  const file = safeFileOrEmpty(root, resultPacket);
  const packet = file && fs.existsSync(file) ? readJson(file) : null;
  const packetStage = String((packet || {}).stage_id || '');
  const packetAttempt = String((packet || {}).stage_attempt_id || '');
  const acceptedCommitId = String((((packet || {}).chapter_commit || {}).accepted_commit_id) || '');
  if (!packet
      || String(packet.workflow_id || '') !== String(task.workflow_id || '')
      || !producerStages.includes(packetStage)
      || planningReviewForProducer(packetStage) !== currentStage
      || String(packet.step_status || '') !== 'completed'
      || String(packet.verification_result || '').toLowerCase() !== 'pass'
      || !packetAttempt
      || !acceptedCommitId) return null;
  const commitFile = path.join(root, '追踪', 'story-system', 'commits', `${acceptedCommitId}.json`);
  const commit = fs.existsSync(commitFile) ? readJson(commitFile) : null;
  if (!commit
      || commit.status !== 'accepted'
      || String(commit.commit_id || '') !== acceptedCommitId
      || String(commit.workflow_id || '') !== String(task.workflow_id || '')
      || String(((commit.provenance || {}).stage_attempt_id) || '') !== packetAttempt
      || !acceptedPlanningArtifactsMatch(root, packet, commit)) return null;
  return { accepted_commit_id: acceptedCommitId, result_packet: resultPacket };
}

function acceptedPlanningArtifactsMatch(root, packet, commit) {
  const targets = normalizedPathArray(packet.result_write_set);
  const changed = normalizedPathArray(packet.changed_files);
  const outputs = Array.isArray(packet.outputs) ? packet.outputs : [];
  const artifacts = Array.isArray(commit.artifacts) ? commit.artifacts : [];
  if (!targets || targets.length === 0 || !changed || !sameArray(targets, changed)
      || outputs.length !== targets.length || artifacts.length !== targets.length) return false;
  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const output = outputs[index] && typeof outputs[index] === 'object' ? outputs[index] : {};
    const artifact = artifacts[index] && typeof artifacts[index] === 'object' ? artifacts[index] : {};
    const outputHash = String(output.sha256 || '').toLowerCase();
    const artifactHash = String(artifact.after_hash || '').toLowerCase();
    const targetFile = safeRegularFile(root, target);
    if (normalizeRel(output.path) !== target
        || normalizeRel(artifact.target) !== target
        || !/^sha256:[a-f0-9]{64}$/.test(outputHash)
        || artifactHash !== outputHash
        || !targetFile
        || hashFile(targetFile).toLowerCase() !== outputHash) return false;
  }
  return true;
}

function applyResult(root, task, resultRel) {
  const run = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'),
    'apply-result', '--project-root', root,
    '--workflow-id', task.workflow_id,
    '--result', safeFile(root, resultRel),
    '--compact', '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  const result = parseJson(run.stdout) || {
    status: 'blocked_apply_result_unreadable',
    stdout: String(run.stdout || '').slice(-1000),
    stderr: String(run.stderr || '').slice(-1000),
  };
  return {
    applied: run.status === 0 && !String(result.status || '').startsWith('blocked_'),
    exitCode: run.status || 0,
    result,
  };
}

function normalizedPathArray(value) {
  if (!Array.isArray(value)) return null;
  const normalized = value.map(normalizeRel);
  return normalized.every(Boolean) ? normalized : null;
}

function hasDuplicates(values) { return new Set(values).size !== values.length; }
function canonicalMatchesProducer(value, producerStage) {
  if (producerStage === 'master_outline') return value === '大纲/总纲.md';
  if (producerStage === 'volume_outline') return /^大纲\/[^/]+\/卷纲\.md$/u.test(value);
  if (producerStage === 'stage_detail_outline') return /^大纲\/[^/]+\/细纲[^/]*\.md$/u.test(value);
  return false;
}
function sameArray(left, right) { return JSON.stringify(left) === JSON.stringify(right); }
function normalizeRel(value) {
  const raw = String(value || '');
  if (!raw || path.isAbsolute(raw)) return '';
  const normalized = raw.replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized === '.' || normalized.startsWith('../') || normalized.includes('/../')) return '';
  return normalized;
}
function safeFile(root, rel) {
  const normalized = normalizeRel(rel);
  const file = normalized ? path.resolve(root, normalized) : '';
  if (!file || file === root || !file.startsWith(`${root}${path.sep}`)) throw failure('blocked_unsafe_path', `unsafe path: ${rel}`);
  let component = root;
  for (const part of path.relative(root, file).split(path.sep).filter(Boolean)) {
    component = path.join(component, part);
    if (fs.existsSync(component) && fs.lstatSync(component).isSymbolicLink()) {
      throw failure('blocked_unsafe_path', `path contains a symbolic link: ${rel}`);
    }
  }
  const realRoot = fs.realpathSync(root);
  let ancestor = file;
  while (!fs.existsSync(ancestor) && ancestor !== root) ancestor = path.dirname(ancestor);
  const realAncestor = fs.realpathSync(ancestor);
  if (realAncestor !== realRoot && !realAncestor.startsWith(`${realRoot}${path.sep}`)) {
    throw failure('blocked_unsafe_path', `path escapes project through symlink: ${rel}`);
  }
  return file;
}
function safeFileOrEmpty(root, rel) { try { return safeFile(root, rel); } catch (_) { return ''; } }
function safeRegularFile(root, rel) {
  const file = safeFileOrEmpty(root, rel);
  if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile() || fs.statSync(file).size === 0) return '';
  return file;
}
function stableAttemptNumber(value) {
  return (crypto.createHash('sha256').update(String(value || '')).digest().readUInt32BE(0) % 2147483646) + 1;
}
function safeSegment(value) { return String(value || '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'attempt'; }
function hashFile(file) { return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`; }
function relativePosix(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(value) { try { return JSON.parse(String(value || '').trim()); } catch (_) { return null; } }
function block(status, detail, extra = {}) { return { status, detail, ...extra, host_started: false }; }
function failure(status, message) { const error = new Error(message); error.status = status; return error; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : `${value.status}\n`}\n`); return code; }
function parseArgs(argv) {
  const out = { projectRoot: '', workflowId: '', apply: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++index] || '';
    else if (arg === '--apply' || arg === '--write') out.apply = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw failure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  if (!out.workflowId && !out.help) throw failure('blocked_invalid_argument', 'missing --workflow-id');
  return out;
}
function help() {
  process.stdout.write('Usage: node long-planning-stage-finalize.js --project-root <book> --workflow-id <id> [--apply] [--json]\n');
  return 0;
}

try { process.exitCode = main(); } catch (error) {
  process.stdout.write(`${JSON.stringify({ status: String(error.status || error.code || 'error'), detail: String(error.message || error), host_started: false })}\n`);
  process.exitCode = 2;
}
