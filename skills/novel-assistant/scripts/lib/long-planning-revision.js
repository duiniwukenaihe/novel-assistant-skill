'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const REVIEW_TO_PRODUCER = Object.freeze({
  master_outline_review: 'master_outline',
  volume_outline_review: 'volume_outline',
});

const PRODUCER_TO_REVIEW = Object.freeze({
  master_outline: 'master_outline_review',
  volume_outline: 'volume_outline_review',
  stage_detail_outline: 'detail_outline_review',
});

function planningProducerForReview(stageId) {
  return REVIEW_TO_PRODUCER[String(stageId || '')] || '';
}

function planningReviewForProducer(stageId) {
  return PRODUCER_TO_REVIEW[String(stageId || '')] || '';
}

function planningRevisionPlanTemplate(stageId) {
  if (!planningProducerForReview(stageId)) return null;
  return {
    version: 'planning_revision_plan_v1',
    summary: 'REPLACE_WITH_READABLE_REVISION_SUMMARY',
    requirements: ['REPLACE_WITH_EXACT_REVISION_REQUIREMENT'],
    targets: ['REPLACE_WITH_TRUSTED_PROJECT_RELATIVE_TARGET'],
  };
}

function validatePlanningRevisionPlan(root, task, result) {
  const reviewStage = String((result || {}).stage_id || (task || {}).current_stage || '');
  const producerStage = planningProducerForReview(reviewStage);
  if (!producerStage || !isBlockingReviewResult(result)) return { status: 'not_applicable' };
  if (String((task || {}).current_stage || '') !== reviewStage
      || String((((task || {}).stage_execution || {}).stage_id) || '') !== reviewStage) {
    return { status: 'not_applicable' };
  }
  const plan = (result || {}).planning_revision_plan;
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) {
    return blocked('blocked_long_planning_revision_plan_missing', '未通过的规划审阅缺少 planning_revision_plan。');
  }
  if (typeof plan.summary !== 'string'
      || !Array.isArray(plan.requirements)
      || !plan.requirements.every((item) => typeof item === 'string')
      || !Array.isArray(plan.targets)
      || !plan.targets.every((item) => typeof item === 'string')) {
    return blocked('blocked_long_planning_revision_plan_invalid', 'planning_revision_plan 的 summary、requirements 和 targets 类型不正确。');
  }
  const summary = plan.summary.trim();
  const requirements = plan.requirements.map((item) => item.trim()).filter(Boolean);
  const targets = plan.targets.map(normalizeRel).filter(Boolean);
  if (String(plan.version || '') !== 'planning_revision_plan_v1' || !summary || requirements.length === 0 || targets.length === 0) {
    return blocked('blocked_long_planning_revision_plan_invalid', 'planning_revision_plan 必须包含版本、可读摘要、非空要求和精确目标。');
  }
  if (requirements.length !== plan.requirements.length || targets.length !== plan.targets.length || hasDuplicates(targets)) {
    return blocked('blocked_long_planning_revision_plan_invalid', 'planning_revision_plan 含有空要求、重复目标或不安全路径。');
  }
  const authority = authoritativePlanningTargets(root, task, producerStage);
  if (authority.status !== 'ready') return authority;
  if (!sameArray(targets, authority.targets)) {
    return blocked('blocked_long_planning_revision_target_mismatch', '审阅建议目标与工作流冻结的规划资产不一致。', {
      expected_targets: authority.targets,
      actual_targets: targets,
    });
  }
  const normalized = {
    version: 'planning_revision_plan_v1',
    review_stage: reviewStage,
    producer_stage: producerStage,
    summary,
    requirements,
    targets: authority.targets,
  };
  return {
    status: 'accepted',
    plan: normalized,
    digest: planDigest(normalized),
    authority: authority.source,
  };
}

function authoritativePlanningTargets(root, task, producerStage) {
  const projectRoot = path.resolve(root);
  if (producerStage === 'master_outline') {
    const target = '大纲/总纲.md';
    return trustedTarget(projectRoot, target, producerStage)
      ? { status: 'ready', targets: [target], source: 'stage_policy' }
      : blocked('blocked_long_planning_target_recovery_source_missing', '无法唯一恢复总纲正式目标。');
  }
  if (producerStage === 'stage_detail_outline') {
    const targets = normalizedUnique(((task || {}).detail_outline_review_failure || {}).failed_targets || []);
    if (!targets.length || !targets.every((target) => trustedTarget(projectRoot, target, producerStage))) {
      return blocked('blocked_long_planning_target_recovery_source_missing', '无法从细纲审阅身份恢复唯一正式目标。');
    }
    return { status: 'ready', targets, source: 'detail_outline_quality_identities' };
  }
  if (producerStage !== 'volume_outline') {
    return blocked('blocked_long_planning_target_recovery_source_missing', '当前阶段没有长篇规划目标策略。');
  }
  const acceptedRevision = acceptedPlanningRevisionTargets(projectRoot, task, producerStage);
  if (acceptedRevision.status !== 'not_applicable') return acceptedRevision;
  const packet = trustedProducerPacket(projectRoot, task, producerStage);
  if (!packet) return blocked('blocked_long_planning_target_recovery_source_missing', '无法从可信卷纲前驱回执恢复唯一正式目标。');
  const targets = normalizedUnique(Array.isArray(packet.result_write_set) ? packet.result_write_set : packet.changed_files || []);
  if (targets.length !== 1 || !trustedTarget(projectRoot, targets[0], producerStage)) {
    return blocked('blocked_long_planning_target_recovery_source_missing', '可信卷纲前驱没有唯一且匹配卷身份的正式目标。');
  }
  return { status: 'ready', targets, source: 'accepted_predecessor_result' };
}

function trustedProducerPacket(root, task, producerStage) {
  const execution = (task || {}).stage_execution || {};
  if (planningProducerForReview((task || {}).current_stage) !== producerStage
      || planningProducerForReview(execution.stage_id) !== producerStage) return null;
  const history = Array.isArray((task || {}).stage_attempt_history) ? task.stage_attempt_history : [];
  const attempt = history[history.length - 1] || null;
  const attemptId = String((attempt || {}).stage_attempt_id || '');
  const workUnitId = String((attempt || {}).work_unit_id || '');
  if (String((attempt || {}).stage_id || '') !== producerStage
      || String((attempt || {}).status || '') !== 'completed'
      || !attemptId || !workUnitId) return null;
  const rel = normalizeRel((attempt || {}).accepted_result_packet);
  const file = rel ? safeRegularFile(root, rel) : '';
  if (!file) return null;
  try {
    const packet = JSON.parse(fs.readFileSync(file, 'utf8'));
    return String(packet.workflow_id || '') === String((task || {}).workflow_id || '')
        && String(packet.stage_id || '') === producerStage
        && String(packet.stage_attempt_id || '') === attemptId
        && String(packet.work_unit_id || '') === workUnitId
        && String(packet.step_status || '') === 'completed'
        && String(packet.verification_result || '').toLowerCase() === 'pass'
      ? packet
      : null;
  } catch (_) { return null; }
}

function acceptedPlanningRevisionTargets(root, task, producerStage) {
  const execution = (task || {}).stage_execution || {};
  if (String((task || {}).current_stage || '') !== producerStage
      || String(execution.stage_id || '') !== producerStage) return { status: 'not_applicable' };
  const revision = (task || {}).planning_revision;
  if (!revision || typeof revision !== 'object') return { status: 'not_applicable' };
  const plan = revision.plan;
  if (!plan || typeof plan !== 'object' || String(plan.producer_stage || '') !== producerStage) {
    return blocked('blocked_long_planning_target_recovery_source_missing', '已确认的卷纲修订缺少可信计划。');
  }
  const digest = planDigest(plan);
  const frozenDigest = String(revision.plan_digest || '');
  const acceptedDigest = String(revision.accepted_plan_digest || frozenDigest);
  if (!frozenDigest || digest !== frozenDigest || digest !== acceptedDigest) {
    return blocked('blocked_long_planning_target_recovery_source_missing', '已确认的卷纲修订计划 digest 不匹配。');
  }
  const targets = normalizedUnique(plan.targets || []);
  if (targets.length !== 1 || !trustedTarget(root, targets[0], producerStage)) {
    return blocked('blocked_long_planning_target_recovery_source_missing', '已确认的卷纲修订没有唯一安全的正式目标。');
  }
  return { status: 'ready', targets, source: 'accepted_planning_revision' };
}

function trustedTarget(root, rel, stageId) {
  const file = safeRegularFile(root, rel);
  if (!file) return false;
  if (stageId === 'master_outline') return rel === '大纲/总纲.md';
  if (stageId === 'volume_outline') return /^大纲\/[^/]+\/卷纲\.md$/u.test(rel);
  if (stageId === 'stage_detail_outline') return /^大纲\/[^/]+\/细纲[^/]*\.md$/u.test(rel);
  return false;
}

function safeRegularFile(root, rel) {
  const normalized = normalizeRel(rel);
  if (!normalized) return '';
  const resolvedRoot = fs.realpathSync(path.resolve(root));
  const candidate = path.resolve(resolvedRoot, normalized);
  if (!candidate.startsWith(`${resolvedRoot}${path.sep}`)) return '';
  try {
    const stat = fs.lstatSync(candidate);
    if (!stat.isFile() || stat.isSymbolicLink()) return '';
    const real = fs.realpathSync(candidate);
    return real.startsWith(`${resolvedRoot}${path.sep}`) ? real : '';
  } catch (_) { return ''; }
}

function isBlockingReviewResult(result) {
  const step = String((result || {}).step_status || '').toLowerCase();
  const verification = String((result || {}).verification_result || '').toLowerCase();
  const action = String((((result || {}).lifecycle_transition_request || {}).action) || '').toLowerCase();
  return ['failed', 'blocked', 'rejected'].includes(step)
    || /fail|reject|block|revise/.test(verification)
    || action === 'return';
}

function planDigest(plan) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(plan)).digest('hex')}`;
}

function normalizedUnique(values) {
  const normalized = Array.isArray(values) ? values.map(normalizeRel) : [];
  if (normalized.some((item) => !item) || hasDuplicates(normalized)) return [];
  return normalized;
}

function normalizeRel(value) {
  const raw = String(value || '').trim();
  if (!raw || path.isAbsolute(raw) || /[*?\[\]{}]/.test(raw)) return '';
  const normalized = raw.replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized === '.' || normalized.startsWith('../') || normalized.includes('/../')) return '';
  return normalized;
}

function hasDuplicates(values) { return new Set(values).size !== values.length; }
function sameArray(left, right) { return JSON.stringify(left) === JSON.stringify(right); }
function blocked(status, detail, extra = {}) { return { status, detail, ...extra }; }

module.exports = {
  authoritativePlanningTargets,
  isBlockingReviewResult,
  planningProducerForReview,
  planningReviewForProducer,
  planningRevisionPlanTemplate,
  planDigest,
  validatePlanningRevisionPlan,
};
