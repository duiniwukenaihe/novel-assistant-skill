#!/usr/bin/env node
'use strict';

const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  normalizeMigrationSource,
  applyLifecycleIndexMigration,
  lifecycleMigrationPlan,
  scanWorkflowMigrations,
  writeMigrationInventory,
} = require('./lib/workflow-legacy-migration');

const stateMachine = path.join(__dirname, 'workflow-state-machine.js');
const cliArgs = process.argv.slice(2);
const request = migrationRequest(cliArgs);
const source = sourceConfig(request.source);
if (!source) finishSourceBlock(request.source ? 'blocked_migration_source_invalid' : 'blocked_migration_source_required', request.source
  ? '仅支持 --source oh-story 或 --source novel-assistant-previous。'
  : '迁移必须显式指定 --source oh-story。');
const sourceScan = scanWorkflowMigrations(request.projectRoot, { migrationSource: source.migrationSource });
const lifecycleSelection = selectedLifecycleMigration(request, sourceScan, source.migrationSource);
if (!request.write) {
  finishJson({
    schemaVersion: '1.0.0',
    status: 'migration_preview',
    migration_inventory: sourceBoundInventory(sourceScan.inventory, source.migrationSource),
    migrated_count: 0,
    safe_default: '默认只预演；作者确认具体 workflow_id 后才允许写入迁移元数据。',
    ...(lifecycleSelection ? lifecycleMigrationPlan(request.projectRoot, lifecycleSelection) : {}),
  });
}
if (!request.workflowId) finishJson({
  schemaVersion: '1.0.0',
  status: 'blocked_migration_confirmation_required',
  migration_inventory: sourceBoundInventory(sourceScan.inventory, source.migrationSource),
  reason: '--write 必须显式提供 --workflow-id。',
  migrated_count: 0,
}, 2);
const unknownLifecycle = sourceScan.records.find(record => record.inventory_item.workflow_id === request.workflowId
  && record.inventory_item.migration_adapter === 'legacy_longform_lifecycle_index'
  && !record.inventory_item.migration_source);
if (unknownLifecycle) finishJson({
  schemaVersion: '1.0.0',
  status: 'blocked_lifecycle_migration_source_unknown',
  ...lifecycleMigrationPlan(request.projectRoot, unknownLifecycle),
}, 2);
if (lifecycleSelection) {
  try {
    const indexFile = path.join(request.projectRoot, '追踪', 'workflow', 'longform-lifecycle.json');
    const existingIndex = readJson(indexFile);
    const matchingIndex = existingIndex
      && String((((existingIndex || {}).migration || {}).migrated_from_workflow_id) || '') === request.workflowId
      && String((((existingIndex || {}).migration || {}).source) || '') === source.migrationSource;
    const migration = matchingIndex
      ? {
        source: source.migrationSource,
        workflow_id: request.workflowId,
        lifecycle_index_path: relative(request.projectRoot, indexFile),
        historical_snapshot_path: String((((existingIndex || {}).migration || {}).historical_snapshot_path) || ''),
        creative_files_changed: false,
        resumed_from_existing_index: true,
      }
      : applyLifecycleIndexMigration(request.projectRoot, lifecycleSelection);
    const successor = cp.spawnSync(process.execPath, [
      stateMachine,
      'migrate-longform-successor',
      '--project-root', request.projectRoot,
      '--workflow-id', request.workflowId,
      '--source', request.source,
      '--confirm',
      '--json',
    ], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    if (successor.error) throw successor.error;
    const successorOutput = JSON.parse(successor.stdout || '{}');
    if (successor.status !== 0 || successorOutput.status !== 'longform_successor_created') {
      finishJson({
        schemaVersion: '1.0.0',
        status: 'blocked_longform_successor_creation',
        migrated_count: 0,
        lifecycle_migration: migration,
        successor: successorOutput,
      }, 2);
    }
    finishJson({
      schemaVersion: '1.0.0',
      status: 'lifecycle_migration_applied',
      migrated_count: 1,
      ...migration,
      successor: successorOutput,
      successor_workflow_id: successorOutput.successor_workflow_id,
      restart_lifecycle_node: successorOutput.current_stage,
      visible_response: successorOutput.visible_response,
    });
  } catch (error) {
    finishJson({
      schemaVersion: '1.0.0',
      status: error.code === 'LIFECYCLE_MIGRATION_SOURCE_UNKNOWN'
        ? 'blocked_lifecycle_migration_source_unknown'
        : 'blocked_lifecycle_migration_conflict',
      ...(error.plan || lifecycleMigrationPlan(request.projectRoot, lifecycleSelection)),
    }, 2);
  }
}
const selection = selectedMigration(request, sourceScan, source.migrationSource);
if (!selection) finishJson({
  schemaVersion: '1.0.0',
  status: 'blocked_migration_selection_invalid',
  migration_inventory: sourceBoundInventory(sourceScan.inventory, source.migrationSource),
  reason: '所选 workflow_id 不是可迁移的 worldwonderer/oh-story-claudecode 旧审阅任务。',
}, 2);
if (selection && selection.requiresConfirmation && !selection.confirmed) {
  process.stdout.write(`${JSON.stringify({
    schemaVersion: '1.0.0',
    status: 'blocked_migration_confirmation_required',
    workflow_id: selection.record.inventory_item.workflow_id,
    reason: '该审阅任务在原始清单中需要确认；请使用 --confirm 执行迁移。',
  }, null, 2)}\n`);
  process.exit(2);
}
const migration = selection ? prepareSelectedMigration(selection) : null;

const result = cp.spawnSync(process.execPath, [stateMachine, 'migrate-legacy', ...cliArgs], {
  encoding: 'utf8',
  maxBuffer: 8 * 1024 * 1024,
});

if (migration) restoreCurrentTask(migration, result.status !== 0 || migration.restoreCurrent);

if (result.status === 0) {
  try {
    const output = JSON.parse(result.stdout);
    if (migration && output.status === 'migration_applied') enrichMigrationRollback(migration, output);
    sourceBoundOutput(request.projectRoot, output, source.migrationSource);
    result.stdout = `${JSON.stringify(output, null, 2)}\n`;
  } catch (error) {
    process.stderr.write(`legacy migration rollback metadata warning: ${error.message}\n`);
    process.exit(1);
  }
}

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if (result.error) {
  process.stderr.write(`${result.error.message}\n`);
  process.exit(1);
}
process.exit(Number.isInteger(result.status) ? result.status : 1);

function selectedMigration(request, scan, migrationSource) {
  const record = scan.records.find((candidate) => candidate.inventory_item.workflow_id === request.workflowId
    && candidate.inventory_item.migration_adapter === 'legacy_fixed_review_batches'
    && candidate.inventory_item.migration_source === migrationSource
    && ['auto-safe', 'confirm-required'].includes(candidate.inventory_item.classification));
  return record ? {
    root: request.projectRoot,
    record,
    migrationSource,
    confirmed: request.confirmed,
    requiresConfirmation: record.inventory_item.classification === 'confirm-required',
  } : null;
}

function selectedLifecycleMigration(request, scan, migrationSource) {
  const candidates = scan.records.filter(candidate => candidate.inventory_item.migration_adapter === 'legacy_longform_lifecycle_index'
    && candidate.inventory_item.migration_source === migrationSource
    && candidate.inventory_item.classification === 'auto-safe');
  if (request.workflowId) return candidates.find(candidate => candidate.inventory_item.workflow_id === request.workflowId) || null;
  return candidates.length === 1 ? candidates[0] : null;
}

function prepareSelectedMigration(selection) {
  const { root, record } = selection;
  const currentPath = path.join(root, '追踪', 'workflow', 'current-task.json');
  const current = snapshotFile(currentPath);
  const copies = captureLegacyCopies(root, record);
  const boundTask = { ...record.task, migration_source: selection.migrationSource };
  fs.mkdirSync(path.dirname(currentPath), { recursive: true });
  writeFileAtomic(currentPath, JSON.stringify(boundTask, null, 2) + '\n');
  return { root, record, migrationSource: selection.migrationSource, currentPath, current, copies, restoreCurrent: !record.active };
}

function captureLegacyCopies(root, record) {
  const values = new Map();
  for (const relativePath of record.inventory_item.source_paths || []) {
    const absolutePath = resolveProjectPath(root, relativePath);
    if (!absolutePath || !fs.existsSync(absolutePath)) continue;
    values.set(relativePath, fs.readFileSync(absolutePath, 'utf8'));
  }
  const fallback = JSON.stringify(record.task, null, 2) + '\n';
  return {
    currentTask: values.get('追踪/workflow/current-task.json') || fallback,
    durableTask: Array.from(values.entries()).find(([file]) => /追踪\/workflow\/tasks\/[^/]+\/task\.json$/.test(file))?.[1] || fallback,
    sourcePaths: Array.from(values.keys()).sort(),
  };
}

function restoreCurrentTask(migration, shouldRestore) {
  if (!shouldRestore) return;
  if (migration.current.exists) writeFileAtomic(migration.currentPath, migration.current.content);
  else if (fs.existsSync(migration.currentPath)) fs.rmSync(migration.currentPath);
}

function enrichMigrationRollback(migration, output) {
  const entry = Array.isArray(output.migrations) ? output.migrations[0] : null;
  if (!entry || !entry.successor_workflow_id) throw new Error('migration result is missing its successor workflow id');
  const workflowId = migration.record.inventory_item.workflow_id;
  const archiveDir = path.join(migration.root, '追踪', 'workflow', 'archived');
  fs.mkdirSync(archiveDir, { recursive: true });
  const archivedCurrent = path.join(archiveDir, `${workflowId}.current-task.json`);
  const archivedDurable = path.join(archiveDir, `${workflowId}.task.json`);
  const snapshot = path.join(archiveDir, `${workflowId}.legacy-snapshot.json`);
  writeFileAtomic(archivedCurrent, migration.copies.currentTask);
  writeFileAtomic(archivedDurable, migration.copies.durableTask);
  writeJsonAtomic(snapshot, {
    schemaVersion: '2.0.0',
    workflow_id: workflowId,
    captured_at: new Date().toISOString(),
    rollback: {
      source_paths: migration.copies.sourcePaths,
      archived_current_task_path: relative(migration.root, archivedCurrent),
      archived_durable_task_path: relative(migration.root, archivedDurable),
    },
  });
  const rollback = {
    snapshot_path: relative(migration.root, snapshot),
    archived_current_task_path: relative(migration.root, archivedCurrent),
    archived_durable_task_path: relative(migration.root, archivedDurable),
    source_paths: migration.copies.sourcePaths,
    source: migration.migrationSource,
  };
  const successorPath = path.join(migration.root, '追踪', 'workflow', 'tasks', entry.successor_workflow_id, 'task.json');
  updateSuccessorMetadata(successorPath, rollback);
  const currentPath = path.join(migration.root, '追踪', 'workflow', 'current-task.json');
  const current = readJson(currentPath);
  if (current && current.workflow_id === entry.successor_workflow_id) updateSuccessorMetadata(currentPath, rollback);
  entry.rollback = rollback;
}

function updateSuccessorMetadata(file, rollback) {
  const task = readJson(file);
  if (!task) throw new Error(`successor task missing: ${file}`);
  task.migration = { ...(task.migration || {}), source: rollback.source, rollback };
  writeJsonAtomic(file, task);
}

function snapshotFile(file) {
  return fs.existsSync(file) ? { exists: true, content: fs.readFileSync(file, 'utf8') } : { exists: false, content: '' };
}

function readJson(file) {
  try {
    return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  } catch {
    return null;
  }
}

function resolveProjectPath(root, relativePath) {
  const absolute = path.resolve(root, relativePath);
  return absolute === root || absolute.startsWith(`${root}${path.sep}`) ? absolute : '';
}

function relative(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function writeJsonAtomic(file, value) {
  writeFileAtomic(file, `${JSON.stringify(value, null, 2)}\n`);
}

function writeFileAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temp, value);
  fs.renameSync(temp, file);
}

function migrationRequest(argv) {
  const request = { projectRoot: '', workflowId: '', source: '', write: false, confirmed: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') request.projectRoot = argv[index + 1] || '';
    else if (arg === '--workflow-id') request.workflowId = argv[index + 1] || '';
    else if (arg === '--source') request.source = argv[index + 1] || '';
    else if (arg === '--write') request.write = true;
    else if (arg === '--confirm') request.confirmed = true;
  }
  request.projectRoot = path.resolve(request.projectRoot || process.cwd());
  return request;
}

function sourceBoundOutput(root, output, migrationSource) {
  if (!output || !output.migration_inventory) return;
  output.migration_inventory = sourceBoundInventory(output.migration_inventory, migrationSource);
  if (output.migration_inventory_path) writeMigrationInventory(root, output.migration_inventory);
}

function sourceBoundInventory(inventory, migrationSource) {
  const items = (inventory.items || []).filter(item => item.migration_source === migrationSource);
  return {
    ...inventory,
    source: migrationSource,
    sources_scanned: items.flatMap(item => item.source_paths || []).sort(),
    items,
    summary: summarize(items),
  };
}

function sourceConfig(value) {
  const migrationSource = normalizeMigrationSource(value);
  return migrationSource ? { migrationSource } : null;
}

function summarize(items) {
  const classifications = ['no-op', 'auto-safe', 'confirm-required', 'read-only-compatible', 'blocked'];
  return Object.fromEntries(classifications.map(classification => [classification, items.filter(item => item.classification === classification).length]));
}

function finishSourceBlock(status, reason) {
  finishJson({ schemaVersion: '1.0.0', status, reason }, 2);
}

function finishJson(value, code = 0) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  process.exit(code);
}
