#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acquireProjectLock, atomicWriteJson } = require('./lib/workflow-state-store');
const { readFocusedTask, writeFocusPointer } = require('./lib/workflow-task-authority');
const {
  ensureTaskFamily,
  identityForTask,
  listTaskFamilies,
} = require('./lib/task-family-store');

const SUPPORTED_SOURCES = new Set(['oh-story', 'novel-assistant']);
const TERMINAL = new Set(['completed', 'completed_verified', 'done', 'pass', 'closed', 'cancelled', 'canceled']);
const USAGE = 'Usage: node scripts/task-family-migrate.js --project-root <book-dir> --source <oh-story|novel-assistant> [--write --confirm] [--json]';

function main(argv = process.argv) {
  const args = parseArgs(argv);
  const root = path.resolve(args.projectRoot);
  const sourceCheck = validateSource(root, args.source);
  if (!sourceCheck.ok) return print({ schemaVersion: '1.0.0', status: 'blocked_task_family_migration_source', message: sourceCheck.message }, args.json, 2);

  const collected = collectTasks(root);
  const preview = buildPreview(root, collected);
  if (!args.write) return print(preview, args.json, 0);
  if (!args.confirm) return print({ ...preview, status: 'blocked_task_family_migration_confirmation_required', message: '迁移仅修改 workflow 元数据；请使用 --write --confirm 确认。' }, args.json, 2);
  if (collected.conflicts.length) return print({ ...preview, status: 'blocked_task_family_migration_state_conflict', message: 'current-task 与 durable task.json 不一致，需先修复状态分叉。' }, args.json, 2);

  const creativeBefore = hashCreativeAssets(root);
  const release = acquireProjectLock(root, 'task-family-migrate');
  try {
    const migrated = migrate(root, collected.tasks, args.source);
    const creativeAfter = hashCreativeAssets(root);
    const unchanged = JSON.stringify(creativeBefore) === JSON.stringify(creativeAfter);
    const result = {
      ...preview,
      status: unchanged ? 'task_family_migration_applied' : 'blocked_task_family_migration_creative_drift',
      migrated_task_count: migrated.length,
      migrated_workflow_ids: migrated.map(item => item.workflow_id),
      task_family_count: listTaskFamilies(root).families.length,
      creative_assets_unchanged: unchanged,
      migration_log: writeMigrationLog(root, { source: args.source, preview, migrated, creativeBefore, creativeAfter, unchanged }),
    };
    return print(result, args.json, unchanged ? 0 : 2);
  } finally {
    release();
  }
}

function parseArgs(argv) {
  const args = { projectRoot: '', source: '', write: false, confirm: false, json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--source') args.source = argv[++index] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.projectRoot || !args.source || !SUPPORTED_SOURCES.has(args.source)) throw new Error(USAGE);
  return args;
}

function validateSource(root, source) {
  const deployedFile = path.join(root, '.story-deployed');
  if (!fs.existsSync(deployedFile)) return { ok: false, message: '缺少 .story-deployed，无法确认这是可迁移的上游或旧版项目。' };
  const deployed = fs.readFileSync(deployedFile, 'utf8').toLowerCase();
  if (source === 'oh-story' && /oh-story|worldwonderer/.test(deployed)) return { ok: true };
  if (source === 'novel-assistant' && /novel[-_]assistant/.test(deployed)) return { ok: true };
  return { ok: false, message: `项目部署标识与 --source ${source} 不匹配。` };
}

function collectTasks(root) {
  const byId = new Map();
  const conflicts = [];
  const readTask = (file, kind) => {
    const task = readJson(file);
    if (!task || task.__error || !task.workflow_id || TERMINAL.has(String(task.status || '').toLowerCase()) || String((task.lifecycle || {}).status || '').toLowerCase() === 'superseded') return;
    const id = String(task.workflow_id);
    const relative = rel(root, file);
    const existing = byId.get(id);
    if (!existing) {
      byId.set(id, { task, paths: [relative], active: kind === 'current' });
      return;
    }
    existing.paths.push(relative);
    existing.active = existing.active || kind === 'current';
    if (stableTaskDigest(existing.task) !== stableTaskDigest(task)) conflicts.push({ workflow_id: id, paths: existing.paths.slice().sort() });
  };
  const currentTaskPath = path.join(root, '追踪', 'workflow', 'current-task.json');
  const currentTask = readJson(currentTaskPath);
  if (isFocusPointer(currentTask)) {
    const focused = readFocusedTask(root);
    if (focused.authority.status === 'ok') readTask(focused.authority.taskFile, 'current');
    else conflicts.push({
      workflow_id: String(currentTask.workflow_id),
      paths: [rel(root, currentTaskPath), rel(root, focused.authority.taskFile || path.join(root, currentTask.task_dir, 'task.json'))],
      reason: '焦点指针找不到对应的权威任务快照。',
    });
  } else {
    readTask(currentTaskPath, 'current');
  }
  const tasksDir = path.join(root, '追踪', 'workflow', 'tasks');
  if (fs.existsSync(tasksDir)) {
    for (const item of fs.readdirSync(tasksDir, { withFileTypes: true })) {
      if (item.isDirectory()) readTask(path.join(tasksDir, item.name, 'task.json'), 'durable');
    }
  }
  return { tasks: Array.from(byId.values()), conflicts };
}

function isFocusPointer(task) {
  return Boolean(task)
    && !task.__error
    && Boolean(String(task.workflow_id || ''))
    && Boolean(String(task.task_dir || ''))
    && !String(task.workflow_type || '')
    && !String(task.user_goal || '');
}

function stableTaskDigest(task) {
  return crypto.createHash('sha256').update(JSON.stringify(canonicalize(task))).digest('hex');
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonicalize(value[key])]));
}

function buildPreview(root, collected) {
  const tasks = collected.tasks.map(record => record.task);
  const identities = tasks.map(task => ({ workflow_id: task.workflow_id, identity: identityForTask(root, task) }));
  const overlaps = [];
  for (let left = 0; left < identities.length; left += 1) {
    for (let right = left + 1; right < identities.length; right += 1) {
      const a = identities[left]; const b = identities[right];
      if (!explicitlyLinked(tasks[left], tasks[right])
        && a.identity.workflow_class === b.identity.workflow_class
        && a.identity.normalized_scope === b.identity.normalized_scope
        && a.identity.objective_kind !== b.identity.objective_kind) {
        overlaps.push({ workflow_ids: [a.workflow_id, b.workflow_id], scope: a.identity.normalized_scope, reason: '同范围但操作不同，保持为独立任务族。' });
      }
    }
  }
  return {
    schemaVersion: '1.0.0',
    status: 'task_family_migration_preview',
    project_root: root,
    candidate_task_count: tasks.length,
    already_bound_count: tasks.filter(task => task.task_family_id).length,
    pending_task_count: tasks.filter(task => !task.task_family_id).length,
    ambiguous_overlap_count: overlaps.length,
    ambiguous_overlaps: overlaps,
    state_conflicts: collected.conflicts,
    metadata_only: true,
    authority_metadata_changes: tasks.filter(task => !task.task_family_id || !task.authority_metadata).map(task => ({
      workflow_id: task.workflow_id,
      task_dir: normalizeTaskDir(task.workflow_id, task.task_dir),
      changes: [
        !task.task_family_id ? 'add task_family_id' : null,
        !task.branch_id ? 'add branch_id' : null,
        !task.authority_metadata ? 'add authority_metadata' : null,
        'convert focused current-task.json to pointer-only schema when active',
      ].filter(Boolean),
    })),
    creative_assets_assurance: '迁移只写追踪/workflow/ 任务元数据，不会修改正文、大纲、细纲、设定或审查正文资产。',
  };
}

function explicitlyLinked(left, right) {
  const leftLifecycle = left.lifecycle || {};
  const rightLifecycle = right.lifecycle || {};
  const leftLinks = [left.parent_workflow_id, leftLifecycle.previous_workflow_id, leftLifecycle.focus_switched_from, leftLifecycle.focus_switched_to].map(String);
  const rightLinks = [right.parent_workflow_id, rightLifecycle.previous_workflow_id, rightLifecycle.focus_switched_from, rightLifecycle.focus_switched_to].map(String);
  return leftLinks.includes(String(right.workflow_id)) || rightLinks.includes(String(left.workflow_id));
}

function migrate(root, records, source) {
  const ordered = [...records].sort((a, b) => Number(Boolean((a.task.lifecycle || {}).focus_switched_from)) - Number(Boolean((b.task.lifecycle || {}).focus_switched_from)));
  const migrated = [];
  for (const record of ordered) {
    const task = { ...record.task, lifecycle: { ...(record.task.lifecycle || {}) } };
    task.task_dir = normalizeTaskDir(task.workflow_id, task.task_dir);
    const registration = ensureTaskFamily(root, task, { write: true, projectLockHeld: true });
    task.task_family_id = registration.family.task_family_id;
    task.branch_id = task.workflow_id;
    task.branch_status = String((registration.branch || {}).status || 'active');
    task.task_family_migrated_at = new Date().toISOString();
    task.authority_metadata = {
      schemaVersion: '1.0.0',
      migrated_at: task.task_family_migrated_at,
      migration_source: String(source || (task.migration || {}).source || task.migration_source || ''),
      task_source: 'task_snapshot',
      focus_role: 'ui_pointer',
      durable_task_path: task.task_dir + '/task.json',
    };
    const taskPath = task.task_dir + '/task.json';
    atomicWriteJson(path.join(root, taskPath), task);
    if (record.active) writeFocusPointer(root, task);
    migrated.push({ workflow_id: task.workflow_id, task_family_id: task.task_family_id, active: record.active });
  }
  return migrated;
}

function normalizeTaskDir(workflowId, taskDir) {
  const expected = path.posix.join('追踪', 'workflow', 'tasks', String(workflowId || ''));
  return String(taskDir || expected).replace(/\\/g, '/').replace(/^\.\//, '') || expected;
}

function hashCreativeAssets(root) {
  const topLevel = ['正文', '大纲', '细纲', '设定', '追踪/伏笔.md', '追踪/上下文.md', '追踪/审查报告'];
  const result = {};
  for (const relativePath of topLevel) {
    const target = path.join(root, relativePath);
    for (const file of listFiles(target)) result[rel(root, file)] = hashFile(file);
  }
  return result;
}

function listFiles(target) {
  if (!fs.existsSync(target)) return [];
  const stat = fs.statSync(target);
  if (stat.isFile()) return [target];
  const found = [];
  for (const item of fs.readdirSync(target, { withFileTypes: true })) found.push(...listFiles(path.join(target, item.name)));
  return found;
}

function writeMigrationLog(root, value) {
  const file = path.join(root, '追踪', 'workflow', 'task-family-migration.json');
  atomicWriteJson(file, { ...value, migrated_at: new Date().toISOString() });
  return rel(root, file);
}

function hashFile(file) { return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`; }
function readJson(file) { try { return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null; } catch (error) { return { __error: error.message }; } }
function rel(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function print(value, json, code) { if (json) console.log(JSON.stringify(value, null, 2)); else console.log(value.status); process.exitCode = code; return value; }

try { main(); } catch (error) { print({ schemaVersion: '1.0.0', status: 'task_family_migration_error', message: error.message }, process.argv.includes('--json'), 2); }
