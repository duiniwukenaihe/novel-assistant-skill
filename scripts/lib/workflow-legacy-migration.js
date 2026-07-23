'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson, acquireProjectLock } = require('./workflow-state-store');
const { LIFECYCLE_NODES, deriveMaturity, normalizeLifecycleState } = require('./longform-lifecycle');
const { discoverLifecycleAssets } = require('../longform-lifecycle-status');

const CLASSIFICATIONS = ['no-op', 'auto-safe', 'confirm-required', 'read-only-compatible', 'blocked'];
const OH_STORY_MIGRATION_SOURCE = 'worldwonderer/oh-story-claudecode';
const PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE = 'novel-assistant/previous-version';
const SUPPORTED_MIGRATION_SOURCES = new Set([OH_STORY_MIGRATION_SOURCE, PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE]);
const TERMINAL_STATUSES = new Set(['completed', 'completed_verified', 'done', 'pass', 'closed', 'cancelled', 'canceled']);
const HIGH_RISK_REVIEW_STAGES = new Set(['execute_repair', 'repair', 'prose', 'chapter_commit', 'closure']);
const LIFECYCLE_INDEX_PATH = path.join('追踪', 'workflow', 'longform-lifecycle.json');
const REVIEW_FOR_ASSET = {
  positioning: 'positioning_review',
  story_bible: 'story_bible',
  master_outline: 'master_outline_review',
  volume_outline: 'volume_outline_review',
  stage_detail_outline: 'detail_outline_review',
  chapter_brief: 'brief_review',
  prose: 'prose_acceptance',
};

function normalizeMigrationSource(value) {
  if (value === 'oh-story' || value === OH_STORY_MIGRATION_SOURCE) return OH_STORY_MIGRATION_SOURCE;
  if (value === 'novel-assistant' || value === 'novel-assistant-previous' || value === PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE) {
    return PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE;
  }
  return '';
}

function scanWorkflowMigrations(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const records = collectWorkflowRecords(root);
  const items = records.map(record => classifyRecord(root, record, options));
  const summary = Object.fromEntries(CLASSIFICATIONS.map(classification => [classification, items.filter(item => item.classification === classification).length]));
  return {
    inventory: {
      schemaVersion: '1.0.0',
      status: 'migration_inventory',
      project_root: root,
      default_mode: 'preview_only',
      non_creative_only: true,
      sources_scanned: Array.from(new Set(records.flatMap(record => record.source_paths))).sort(),
      items,
      summary,
    },
    records: records.map((record, index) => ({ ...record, inventory_item: items[index] })),
  };
}

function writeMigrationInventory(projectRoot, inventory) {
  const root = path.resolve(projectRoot);
  const file = path.join(root, '追踪', 'workflow', 'migration-inventory.json');
  atomicWriteJson(file, inventory);
  return relative(root, file);
}

function isMigrationSuppressed(item) {
  return Boolean(item)
    && item.workflow_type === 'review_repair'
    && ['auto-safe', 'confirm-required', 'blocked'].includes(item.classification)
    && item.migration_adapter === 'legacy_fixed_review_batches';
}

function collectWorkflowRecords(root) {
  const byKey = new Map();
  const currentPath = path.join(root, '追踪', 'workflow', 'current-task.json');
  collectCurrentTaskRecord(byKey, root, currentPath);

  const tasksDir = path.join(root, '追踪', 'workflow', 'tasks');
  if (fs.existsSync(tasksDir)) {
    for (const entry of fs.readdirSync(tasksDir, { withFileTypes: true })) {
      if (entry.isDirectory()) collectTaskRecord(byKey, root, path.join(tasksDir, entry.name, 'task.json'), 'task_directory', false);
    }
  }

  return Array.from(byKey.values());
}

function collectCurrentTaskRecord(byKey, root, file) {
  const parsed = readJson(file);
  if (!parsed) return;
  const isPointer = !parsed.__error
    && String(parsed.workflow_id || '')
    && String(parsed.task_dir || '')
    && !String(parsed.workflow_type || '')
    && !String(parsed.user_goal || '');
  if (!isPointer) {
    collectTaskRecord(byKey, root, file, 'current_task', true);
    return;
  }
  const taskFile = path.join(root, normalizeRelativePath(parsed.task_dir), 'task.json');
  const task = readJson(taskFile);
  if (!task) {
    collectTaskRecord(byKey, root, file, 'current_task_pointer', true);
    return;
  }
  const key = task.__error ? `invalid:${relative(root, taskFile)}` : `task:${String(task.workflow_id || relative(root, taskFile))}`;
  byKey.set(key, {
    kind: 'task',
    source_kind: 'current_task_pointer',
    source_kinds: ['current_task_pointer', 'task_directory'],
    source_paths: [relative(root, file), relative(root, taskFile)],
    active: true,
    task,
  });
}

function collectTaskRecord(byKey, root, file, sourceKind, active) {
  const parsed = readJson(file);
  if (!parsed) return;
  if (!parsed.__error && String((parsed.lifecycle || {}).status || '').toLowerCase() === 'superseded') return;
  const key = parsed.__error ? `invalid:${relative(root, file)}` : `task:${String(parsed.workflow_id || relative(root, file))}`;
  const existing = byKey.get(key);
  if (existing) {
    existing.source_paths.push(relative(root, file));
    existing.source_kinds.push(sourceKind);
    existing.active = existing.active || active;
    if (active && !parsed.__error) existing.task = parsed;
    return;
  }
  byKey.set(key, {
    kind: 'task',
    source_kind: sourceKind,
    source_kinds: [sourceKind],
    source_paths: [relative(root, file)],
    active,
    task: parsed,
  });
}

function classifyRecord(root, record, options = {}) {
  const task = record.task || {};
  const legacyFixedReview = isLegacyFixedReview(task);
  const legacyLongform = isLegacyLongform(task);
  const source = explicitMigrationSourceWithMatchingStructure(root, task, options);
  const workflowType = String(task.workflow_type || 'unknown');
  const workflowId = String(task.workflow_id || '');
  const safeWorkflowId = isSafeWorkflowId(workflowId);
  const base = {
    id: workflowId || record.source_paths[0],
    workflow_id: workflowId,
    workflow_type: workflowType,
    scope: String(task.scope || ((task.lifecycle || {}).scope) || ''),
    source_paths: Array.from(new Set(record.source_paths)).sort(),
    source_kinds: Array.from(new Set(record.source_kinds || [record.source_kind])).sort(),
    active: Boolean(record.active),
    status: String(task.status || ''),
    risk_level: String(task.risk_level || 'medium'),
    classification: 'no-op',
    reason: '',
    impact: '只读取 workflow 元数据；不修改正文、大纲、设定或其他创作资产。',
    rollback_snapshot: safeWorkflowId ? `追踪/workflow/archived/${workflowId}.${legacyLongform ? 'lifecycle-migration-' : 'legacy-'}snapshot.json` : '',
    migration_adapter: '',
    migration_source: source,
    migration_source_evidence: source ? 'explicit_source_with_matching_project_structure' : '',
  };

  if (task.__error) return { ...base, classification: 'blocked', reason: `任务元数据无法解析：${task.__error}`, impact: '元数据不可信，禁止迁移。' };
  if (!safeWorkflowId) {
    return {
      ...base,
      classification: 'blocked',
      reason: 'workflow_id 不是受支持的安全文件名。',
      impact: '工作流标识不可信，禁止生成快照路径或写入迁移。',
      rollback_snapshot: '',
      migration_adapter: legacyLongform ? 'legacy_longform_lifecycle_index' : (legacyFixedReview ? 'legacy_fixed_review_batches' : ''),
    };
  }
  if (legacyLongform && !SUPPORTED_MIGRATION_SOURCES.has(source)) {
    return {
      ...base,
      classification: 'blocked',
      reason: '旧 long_write 未声明受支持的项目来源；未知来源不得自动迁移到生命周期索引。',
      impact: '来源不可信，禁止创建生命周期元数据。',
      rollback_snapshot: '',
      migration_adapter: 'legacy_longform_lifecycle_index',
    };
  }
  if (legacyFixedReview && !SUPPORTED_MIGRATION_SOURCES.has(source)) {
    return {
      ...base,
      rollback_snapshot: '',
      reason: '旧固定批次审阅未声明受支持的 worldwonderer/oh-story-claudecode 来源；不提供自动兼容迁移。',
    };
  }
  if (!safeTaskDir(task.task_dir)) {
    return {
      ...base,
      classification: 'blocked',
      reason: 'task_dir 不在项目内或包含不安全路径。',
      impact: '路径不可信，禁止迁移。',
      migration_adapter: legacyFixedReview ? 'legacy_fixed_review_batches' : '',
    };
  }
  if (TERMINAL_STATUSES.has(String(task.status || '').toLowerCase()) || String((task.lifecycle || {}).status || '').toLowerCase() === 'superseded') {
    return { ...base, reason: '任务已经终结或已被后继任务取代。' };
  }
  if (legacyFixedReview) {
    if (!record.active) {
      return { ...base, classification: 'confirm-required', reason: '旧固定批次审阅不在 current-task，迁移会替换当前任务，必须人工确认。', migration_adapter: 'legacy_fixed_review_batches' };
    }
    if (requiresConfirmation(task)) {
      return { ...base, classification: 'confirm-required', reason: '旧固定批次审阅处于高风险修复阶段；默认只预演，必须明确确认后才可迁移。', migration_adapter: 'legacy_fixed_review_batches' };
    }
    return { ...base, classification: 'auto-safe', reason: '检测到无现代 review_plan_path/digest 的固定批次/四 agent 审阅；可创建只读证据驱动的后继任务。', migration_adapter: 'legacy_fixed_review_batches' };
  }
  if (legacyLongform) {
    return {
      ...base,
      classification: 'auto-safe',
      reason: '检测到缺少 lifecycle_graph 的旧 long_write；仅可预演或在明确确认后建立作品生命周期索引与历史快照。',
      impact: '只创建生命周期元数据和历史快照；绝不修改正文、大纲、细纲或旧任务。',
      migration_adapter: 'legacy_longform_lifecycle_index',
    };
  }
  if (workflowType === 'review_repair' && (task.review_plan_path || task.review_plan_digest)) {
    return { ...base, classification: 'read-only-compatible', reason: '审阅任务已有持久化计划引用；保持现有只读兼容边界。', migration_adapter: 'none' };
  }
  return { ...base, reason: `暂未定义 ${workflowType} 的自动升级适配器；保持原任务不变。` };
}

function isLegacyFixedReview(task) {
  if (String((task || {}).workflow_type || '') !== 'review_repair') return false;
  if ((task || {}).review_plan_path || (task || {}).review_plan_digest) return false;
  const batches = (task || {}).review_batches || {};
  const agents = Array.isArray(batches.agents) ? batches.agents : Array.isArray(task.review_agents) ? task.review_agents : [];
  return Number(batches.batch_size) === 50 || Number(batches.agent_count) === 4 || agents.length === 4;
}

function isLegacyRuntimeTask(task) {
  return Boolean(task) && !task.__error && isLegacyFixedReview(task);
}

function isLegacyLongform(task) {
  return String((task || {}).workflow_type || '') === 'long_write'
    && !(task || {}).lifecycle_graph;
}

function lifecycleMigrationPlan(projectRoot, record) {
  const root = path.resolve(projectRoot);
  const task = record.task || {};
  const discovered = discoverLifecycleAssets(root);
  const state = normalizeLifecycleState(Object.fromEntries(discovered.assets.map(asset => [asset.id, asset.status])));
  const indexPath = path.join(root, LIFECYCLE_INDEX_PATH);
  const source = record.inventory_item.migration_source || '';
  const unresolvedConflicts = [];
  if (!isSafeWorkflowId(task.workflow_id)) {
    unresolvedConflicts.push({ code: 'workflow_id_invalid', message: 'workflow_id 不是受支持的安全文件名。' });
  }
  if (!SUPPORTED_MIGRATION_SOURCES.has(source)
    || record.inventory_item.migration_source_evidence !== 'explicit_source_with_matching_project_structure'
    || !hasMatchingLegacyProjectStructure(root, task)) {
    unresolvedConflicts.push({ code: 'migration_source_unknown', message: '项目来源未被识别为受支持的旧项目。' });
  }
  if (fs.existsSync(indexPath)) {
    unresolvedConflicts.push({ code: 'lifecycle_index_already_exists', path: LIFECYCLE_INDEX_PATH, message: '已有生命周期索引，迁移器不会覆盖它。' });
  }
  return {
    source,
    workflow_id: String(task.workflow_id || ''),
    detected_assets: discovered.assets.filter(asset => asset.source_path).map(asset => ({
      id: asset.id,
      status: asset.status,
      source_path: asset.source_path,
    })),
    inferred_maturity: deriveMaturity(state),
    proposed_lifecycle_node: proposedLifecycleNode(state),
    unresolved_conflicts: unresolvedConflicts,
    creative_files_changed: false,
    lifecycle_index_path: LIFECYCLE_INDEX_PATH,
  };
}

function applyLifecycleIndexMigration(projectRoot, record) {
  const root = path.resolve(projectRoot);
  const plan = lifecycleMigrationPlan(root, record);
  if (plan.unresolved_conflicts.length > 0) {
    const error = new Error('lifecycle migration has unresolved conflicts');
    error.code = lifecycleMigrationErrorCode(plan);
    error.plan = plan;
    throw error;
  }
  const release = acquireProjectLock(root, 'workflow-legacy-lifecycle-migrate');
  try {
    const checked = lifecycleMigrationPlan(root, record);
    if (checked.unresolved_conflicts.length > 0) {
      const error = new Error('lifecycle migration changed before write');
      error.code = lifecycleMigrationErrorCode(checked);
      error.plan = checked;
      throw error;
    }
    const snapshotPath = path.join(root, '追踪', 'workflow', 'archived', `${checked.workflow_id}.lifecycle-migration-snapshot.json`);
    const indexPath = path.join(root, LIFECYCLE_INDEX_PATH);
    const assets = normalizeLifecycleState(Object.fromEntries(discoverLifecycleAssets(root).assets.map(asset => [asset.id, asset.status])));
    atomicWriteJson(snapshotPath, {
      schemaVersion: '1.0.0',
      kind: 'longform_lifecycle_migration_history',
      source: checked.source,
      workflow_id: checked.workflow_id,
      captured_at: new Date().toISOString(),
      legacy_task: record.task,
    });
    atomicWriteJson(indexPath, {
      schemaVersion: '1.0.0',
      assets,
      migration: {
        kind: 'supported_project_lifecycle_index',
        source: checked.source,
        migrated_from_workflow_id: checked.workflow_id,
        historical_snapshot_path: relative(root, snapshotPath),
        proposed_lifecycle_node: checked.proposed_lifecycle_node,
        earliest_untrusted_node: LIFECYCLE_NODES.find(node => assets[node.id] !== 'accepted')?.id || 'book_acceptance',
        migrated_at: new Date().toISOString(),
      },
    });
    return {
      ...checked,
      lifecycle_index_path: relative(root, indexPath),
      historical_snapshot_path: relative(root, snapshotPath),
      creative_files_changed: false,
    };
  } finally {
    release();
  }
}

function lifecycleMigrationErrorCode(plan) {
  if (plan.unresolved_conflicts.some(conflict => conflict.code === 'workflow_id_invalid')) {
    return 'LIFECYCLE_MIGRATION_WORKFLOW_ID_INVALID';
  }
  if (plan.unresolved_conflicts.some(conflict => conflict.code === 'migration_source_unknown')) {
    return 'LIFECYCLE_MIGRATION_SOURCE_UNKNOWN';
  }
  return 'LIFECYCLE_MIGRATION_CONFLICT';
}

function proposedLifecycleNode(state) {
  const normalized = normalizeLifecycleState(state);
  const repair = LIFECYCLE_NODES.find(node => ['invalidated', 'needs_recheck'].includes(normalized[node.id]));
  if (repair) return repair.id;
  const pendingEvidence = LIFECYCLE_NODES.find(node => normalized[node.id] === 'needs_review');
  if (pendingEvidence) return REVIEW_FOR_ASSET[pendingEvidence.id] || pendingEvidence.id;
  return LIFECYCLE_NODES.find(node => normalized[node.id] !== 'accepted')?.id || '';
}

function explicitMigrationSourceWithMatchingStructure(root, task, options) {
  const source = normalizeMigrationSource((options || {}).migrationSource)
    || migrationSourceFromDeployment(root);
  if (!SUPPORTED_MIGRATION_SOURCES.has(source)) return '';
  // Keep an unsafe identifier visible to the caller so its path-safety block is reported.
  if (!isSafeWorkflowId(task.workflow_id)) return source;
  return hasMatchingLegacyProjectStructure(root, task) ? source : '';
}

function migrationSourceFromDeployment(root) {
  const deployedFile = path.join(root, '.story-deployed');
  if (!fs.existsSync(deployedFile)) return '';
  let raw = '';
  try {
    raw = fs.readFileSync(deployedFile, 'utf8').toLowerCase();
  } catch (_) {
    return '';
  }
  if (/worldwonderer|oh-story/.test(raw)) return OH_STORY_MIGRATION_SOURCE;
  if (/novel[-_]assistant/.test(raw)) return PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE;
  return '';
}

function hasMatchingLegacyProjectStructure(root, task) {
  const workflowRoot = path.join(root, '追踪', 'workflow');
  if (!fs.existsSync(workflowRoot) || !fs.statSync(workflowRoot).isDirectory()) return false;
  if (!hasProjectContent(root, '正文')) return false;
  if (isLegacyLongform(task)) return hasProjectContent(root, '大纲') && hasProjectContent(root, '设定');
  return isLegacyFixedReview(task);
}

function hasProjectContent(root, relativePath) {
  const target = path.join(root, relativePath);
  if (!fs.existsSync(target)) return false;
  const stat = fs.statSync(target);
  if (stat.isFile()) return stat.size > 0;
  if (!stat.isDirectory()) return false;
  return fs.readdirSync(target, { withFileTypes: true }).some(entry => entry.isFile() || entry.isDirectory());
}

function requiresConfirmation(task) {
  const stage = String(task.current_stage || task.current_step || '').toLowerCase();
  const risk = String(task.risk_level || ((task.runtime_guard || {}).token_estimate || {}).risk_level || '').toLowerCase();
  const pending = (task.pending_action || {}).options || [];
  return ['high', 'destructive'].includes(risk)
    || HIGH_RISK_REVIEW_STAGES.has(stage)
    || pending.some(option => option && option.requires_user_confirm === true && ['high', 'destructive'].includes(String(option.risk_level || '').toLowerCase()));
}

function safeTaskDir(value) {
  const normalized = String(value || '');
  return !normalized || (!path.isAbsolute(normalized) && !normalized.split(/[\\/]+/).includes('..'));
}

function normalizeRelativePath(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
}

function isSafeWorkflowId(value) {
  const normalized = String(value || '');
  return Boolean(normalized)
    && path.basename(normalized) === normalized
    && normalized !== '.'
    && normalized !== '..'
    && /^[A-Za-z0-9._-]+$/.test(normalized);
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function relative(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

module.exports = {
  OH_STORY_MIGRATION_SOURCE,
  PREVIOUS_NOVEL_ASSISTANT_MIGRATION_SOURCE,
  normalizeMigrationSource,
  isLegacyRuntimeTask,
  isMigrationSuppressed,
  applyLifecycleIndexMigration,
  lifecycleMigrationPlan,
  scanWorkflowMigrations,
  writeMigrationInventory,
};
