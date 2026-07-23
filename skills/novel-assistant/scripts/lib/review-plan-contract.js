'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');

function validateReviewPlan(plan) {
  if (!isPlainObject(plan)) invalid('review plan must be an object');
  if (plan.schemaVersion !== '2.0.0') invalid('review plan schemaVersion must be 2.0.0');
  if (!nonEmptyString(plan.workflow_id)) invalid('review plan workflow_id is required');
  if (!nonEmptyString(plan.parent_scope)) invalid('review plan parent_scope is required');
  if (!Array.isArray(plan.required_dimensions) || plan.required_dimensions.length === 0
    || plan.required_dimensions.some((dimension) => !nonEmptyString(dimension))) {
    invalid('review plan required_dimensions must contain non-empty strings');
  }
  if (!isPlainObject(plan.source_identity)) invalid('review plan source_identity must be an object');
  if (!isPlainObject(plan.budget_policy)) invalid('review plan budget_policy must be an object');
  if (!Array.isArray(plan.batches)) invalid('review plan batches must be an array');
  const readMode = reviewPlanReadMode(plan);
  const batchIds = new Set();
  for (const batch of plan.batches) {
    if (!isPlainObject(batch) || !nonEmptyString(batch.id) || !nonEmptyString(batch.range)) {
      invalid('each review plan batch requires id and range');
    }
    if (readMode !== 'legacy_read_only') {
      if (!Array.isArray(batch.primary_chapter_keys) || batch.primary_chapter_keys.length === 0
        || batch.primary_chapter_keys.some((chapterKey) => !nonEmptyString(chapterKey))) {
        invalid('each review plan batch requires primary chapter coverage');
      }
      if (!positiveNumber(batch.source_chars) || !positiveNumber(batch.weighted_source_chars) || !positiveNumber(batch.source_budget_chars)) {
        invalid('each review plan batch requires positive source budget evidence');
      }
      if (!nonEmptyString(batch.boundary_reason)
        || !isPlainObject(batch.boundary_context)
        || !Array.isArray(batch.boundary_context.before)
        || !Array.isArray(batch.boundary_context.after)) {
        invalid('each review plan batch requires a boundary reason and context windows');
      }
      if (!Array.isArray(batch.expected_dimensions) || batch.expected_dimensions.length === 0
        || batch.expected_dimensions.some((dimension) => !nonEmptyString(dimension))) {
        invalid('each review plan batch requires expected dimensions');
      }
    }
    if (batchIds.has(batch.id)) invalid(`duplicate review plan batch id: ${batch.id}`);
    batchIds.add(batch.id);
  }
  if (!isPlainObject(plan.coverage_policy)
    || typeof plan.coverage_policy.require_all_chapters !== 'boolean'
    || typeof plan.coverage_policy.allow_unexplained_deferred !== 'boolean') {
    invalid('review plan coverage_policy requires boolean coverage controls');
  }
  return plan;
}

function digestReviewPlan(plan) {
  validateReviewPlan(plan);
  return crypto.createHash('sha256').update(stableJson(plan)).digest('hex');
}

function writeReviewPlan(projectRoot, task, plan) {
  validateReviewPlan(plan);
  const root = path.resolve(projectRoot);
  const reviewPlanPath = relativePlanPath(root, task);
  atomicWriteJson(resolvePlanPath(root, reviewPlanPath), plan);
  return { path: reviewPlanPath, digest: digestReviewPlan(plan) };
}

function readReviewPlan(projectRoot, task) {
  const root = path.resolve(projectRoot);
  const reviewPlanPath = relativePlanPath(root, task, true);
  const expectedDigest = String((task || {}).review_plan_digest || '');
  if (!expectedDigest) missing('review plan digest is missing');
  const file = resolvePlanPath(root, reviewPlanPath);
  if (!fs.existsSync(file)) missing('review plan file is missing');
  let plan;
  try {
    plan = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    stale(`review plan is unreadable: ${error.message}`);
  }
  try {
    validateReviewPlan(plan);
  } catch (error) {
    stale(error.message);
  }
  const digest = digestReviewPlan(plan);
  if (digest !== expectedDigest) stale('review plan digest differs from the task reference');
  return { path: reviewPlanPath, digest, plan, plan_read_mode: reviewPlanReadMode(plan) };
}

function reviewPlanReadMode(plan) {
  if (!plan || !Array.isArray(plan.batches)) return 'current';
  const legacyCount = plan.batches.filter((batch) => !Array.isArray((batch || {}).primary_chapter_keys)
    && isPlainObject((batch || {}).dispatch_plan)).length;
  if (legacyCount === 0) return 'current';
  if (legacyCount === plan.batches.length) return 'legacy_read_only';
  invalid('review plan mixes legacy and evidence-backed batch entries');
}

function legacyReadOnlyBlock(task) {
  return {
    status: 'blocked_review_plan_legacy_read_only',
    workflow_id: String((task || {}).workflow_id || ''),
    plan_read_mode: 'legacy_read_only',
    allowed_actions: ['inspect'],
    migration_action: {
      action_id: 'create_new_review_task',
      workflow_type: 'review_repair',
      scope: String((task || {}).scope || ''),
      description: '旧审阅计划缺少可验证的章节证据，只能查看；请基于当前可信章节证据新建审阅任务。',
    },
  };
}

function relativePlanPath(projectRoot, task, requireExistingReference = false) {
  const taskDir = String((task || {}).task_dir || '');
  const configured = String((task || {}).review_plan_path || '');
  if (requireExistingReference && !configured) missing('review plan path is missing');
  const reviewPlanPath = configured || path.posix.join(taskDir, 'review-plan.json');
  if (!taskDir || !reviewPlanPath || path.isAbsolute(reviewPlanPath)) missing('review plan path is invalid');
  return reviewPlanPath.split(path.sep).join('/');
}

function resolvePlanPath(projectRoot, reviewPlanPath) {
  const root = path.resolve(projectRoot);
  const file = path.resolve(root, reviewPlanPath);
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) missing('review plan path escapes project root');
  return file;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (isPlainObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function positiveNumber(value) {
  return Number.isFinite(Number(value)) && Number(value) > 0;
}

function invalid(message) {
  const error = new Error(message);
  error.code = 'REVIEW_PLAN_INVALID';
  throw error;
}

function missing(message) {
  const error = new Error(message);
  error.code = 'REVIEW_PLAN_MISSING';
  throw error;
}

function stale(message) {
  const error = new Error(message);
  error.code = 'REVIEW_PLAN_STALE';
  throw error;
}

module.exports = {
  validateReviewPlan,
  digestReviewPlan,
  writeReviewPlan,
  readReviewPlan,
  reviewPlanReadMode,
  legacyReadOnlyBlock,
};
