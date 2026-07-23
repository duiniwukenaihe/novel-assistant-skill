'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { createRuntimeSafeFs } = require('./runtime-safe-fs');

const MANIFEST_NAME = '.story-runtime-managed.json';
const SNAPSHOT_ROOT = path.posix.join('追踪', 'runtime-snapshots');
const RETAINED_SNAPSHOT_COUNT = 5;
const SNAPSHOT_TOTAL_BYTE_CAP = 5 * 1024 * 1024;

function planManagedSync({ projectRoot, sourceRoot, previousManifest, bundleId = 'unknown' }) {
  const root = path.resolve(projectRoot);
  const previous = normalizeManifest(previousManifest);
  const previousByPath = new Map(previous.files.map(file => [file.path, file]));
  const desired = collectSourceFiles(sourceRoot).map(file => ({
    ...file,
    sourceHash: hashFile(file.source),
    bundleId,
  })).sort((left, right) => left.path.localeCompare(right.path));
  const desiredPaths = new Set(desired.map(file => file.path));
  const operations = [];

  for (const file of desired) {
    const targetState = inspectTarget(root, file.path);
    const previousFile = previousByPath.get(file.path);
    if (!targetState.exists) {
      operations.push({ action: 'create', file, target: targetState.target, previous: previousFile || null });
      continue;
    }

    const deployedHash = targetState.hash;
    if (!previousFile) {
      operations.push(conflictOperation('unmanaged_existing_file', file, targetState.target, deployedHash, null));
      continue;
    }

    if (deployedHash !== previousFile.deployedHash && deployedHash !== file.sourceHash) {
      operations.push(conflictOperation('managed_file_modified', file, targetState.target, deployedHash, previousFile));
      continue;
    }

    operations.push(deployedHash === file.sourceHash
      ? { action: 'noop', file, target: targetState.target, deployedHash, previous: previousFile }
      : { action: 'update', file, target: targetState.target, deployedHash, previous: previousFile });
  }

  for (const previousFile of previous.files) {
    if (desiredPaths.has(previousFile.path)) continue;
    const targetState = inspectTarget(root, previousFile.path);
    if (!targetState.exists) {
      operations.push({ action: 'forget', file: previousFile, target: targetState.target, previous: previousFile });
      continue;
    }
    const deployedHash = targetState.hash;
    operations.push(deployedHash === previousFile.deployedHash
      ? { action: 'delete', file: previousFile, target: targetState.target, deployedHash, previous: previousFile }
      : conflictOperation('managed_file_modified', previousFile, targetState.target, deployedHash, previousFile));
  }

  const nextManifest = {
    schemaVersion: 1,
    bundleId,
    files: desired.map(file => ({
      path: file.path,
      deployedHash: file.sourceHash,
      sourceHash: file.sourceHash,
      bundleId,
    })),
  };
  const manifestChanged = stableJson(nextManifest) !== stableJson(previous);
  const conflicts = operations.filter(operation => operation.action === 'conflict').map(toConflict);

  return {
    projectRoot: root,
    previousManifest: previous,
    nextManifest,
    operations,
    conflicts,
    manifestChanged,
  };
}

function applyManagedSync(plan, { confirmConflicts = false, safeFs: providedSafeFs = null } = {}) {
  if (plan.conflicts.length && !confirmConflicts) {
    return { status: 'confirmation_required', changed: 0, conflicts: plan.conflicts };
  }

  const changedOperations = plan.operations.filter(operation => ['create', 'update', 'delete', 'conflict'].includes(operation.action));
  const revalidationConflicts = revalidateOperations(plan.projectRoot, changedOperations);
  if (revalidationConflicts.length) {
    return {
      status: 'confirmation_required',
      changed: 0,
      conflicts: plan.conflicts.concat(revalidationConflicts),
    };
  }

  const snapshotOperations = changedOperations.filter(operation => Boolean(operation.previous));
  const preparedSnapshot = snapshotOperations.length ? prepareSnapshot(plan, snapshotOperations) : null;
  const safeFs = providedSafeFs || createRuntimeSafeFs(plan.projectRoot);
  if (safeFs.capability.status !== 'ready') {
    return {
      status: 'blocked_runtime_safe_fs_unavailable',
      changed: 0,
      conflicts: plan.conflicts,
      runtime_safe_fs: safeFs.capability,
    };
  }
  const snapshotId = preparedSnapshot ? createSnapshot(plan, preparedSnapshot, safeFs) : null;

  for (const operation of changedOperations) {
    if (operationDeletesTarget(operation)) {
      safeFs.deleteFile(operation.file.path);
      continue;
    }
    const sourceMode = fs.statSync(operation.file.source).mode & 0o777;
    safeFs.writeFile(operation.file.path, fs.readFileSync(operation.file.source), sourceMode);
  }

  if (plan.manifestChanged) writeManifest(safeFs, plan.nextManifest);
  return {
    status: 'synced',
    changed: changedOperations.length,
    snapshotId,
    conflicts: plan.conflicts,
    runtime_safe_fs: safeFs.capability,
  };
}

function rollbackManagedSync({ projectRoot, snapshotId, confirmConflicts = false }) {
  const root = path.resolve(projectRoot);
  const snapshot = readSnapshot(root, snapshotId);
  const previous = normalizeManifest(snapshot.previousManifest);
  const next = normalizeManifest(snapshot.nextManifest);
  const previousByPath = new Map(previous.files.map(file => [file.path, file]));
  const conflicts = [];

  for (const file of snapshot.files) {
    const targetState = inspectTarget(root, file.path);
    if (targetState.hash !== file.afterHash) {
      conflicts.push({ path: file.path, reason: 'managed_file_modified_since_snapshot' });
    }
  }
  for (const file of next.files) {
    if (previousByPath.has(file.path)) continue;
    const targetState = inspectTarget(root, file.path);
    if (!targetState.exists || targetState.hash !== file.deployedHash) {
      conflicts.push({ path: file.path, reason: 'managed_file_modified_since_snapshot' });
    }
  }
  if (conflicts.length && !confirmConflicts) return { status: 'confirmation_required', conflicts };

  const safeFs = createRuntimeSafeFs(root);
  if (safeFs.capability.status !== 'ready') {
    return {
      status: 'blocked_runtime_safe_fs_unavailable',
      snapshotId,
      conflicts,
      runtime_safe_fs: safeFs.capability,
    };
  }

  for (const file of next.files) {
    if (previousByPath.has(file.path)) continue;
    safeFs.deleteFile(file.path);
  }
  for (const file of snapshot.files) {
    safeFs.copyFile(snapshotFileRelativePath(snapshotId, file.path), file.path, file.mode === null ? 0o644 : file.mode);
  }
  writeManifest(safeFs, previous);
  return { status: 'rolled_back', snapshotId, conflicts, runtime_safe_fs: safeFs.capability };
}

function prepareSnapshot(plan, operations) {
  const snapshotBase = snapshotRootPath(plan.projectRoot);
  assertNoSymlinkTree(snapshotBase);
  const snapshotId = nextSnapshotId(snapshotBase);
  const snapshot = buildSnapshot(plan, operations, snapshotId);
  const snapshotBytes = snapshot.files.reduce((total, file) => total + file.size, 0)
    + Buffer.byteLength(`${JSON.stringify(snapshot, null, 2)}\n`);
  const existingBytes = lstatIfExists(snapshotBase) ? directoryBytes(snapshotBase) : 0;
  if (existingBytes + snapshotBytes > SNAPSHOT_TOTAL_BYTE_CAP) {
    throw new Error(`runtime snapshot byte cap would be exceeded: ${SNAPSHOT_TOTAL_BYTE_CAP}`);
  }

  return { snapshotId, snapshot };
}

function createSnapshot(plan, preparedSnapshot, safeFs) {
  const { snapshotId, snapshot } = preparedSnapshot;
  for (const file of snapshot.files) {
    safeFs.copyFile(file.path, snapshotFileRelativePath(snapshotId, file.path), file.mode);
  }
  safeFs.writeFile(snapshotManifestRelativePath(snapshotId), Buffer.from(`${JSON.stringify(snapshot, null, 2)}\n`), 0o644);
  pruneSnapshots(plan.projectRoot, safeFs);
  return snapshotId;
}

function buildSnapshot(plan, operations, snapshotId) {
  return {
    schemaVersion: 1,
    snapshotId,
    previousManifest: plan.previousManifest,
    nextManifest: plan.nextManifest,
    files: operations.map(operation => {
      const targetState = inspectTarget(plan.projectRoot, operation.file.path);
      return {
        path: operation.file.path,
        beforeHash: targetState.hash,
        afterHash: operationDeletesTarget(operation) ? null : operation.file.sourceHash,
        mode: targetState.stat.mode & 0o777,
        size: targetState.stat.size,
      };
    }),
  };
}

function revalidateOperations(projectRoot, operations) {
  const conflicts = [];
  for (const operation of operations) {
    const targetState = inspectTarget(projectRoot, operation.file.path);
    if (operation.action === 'create') {
      if (targetState.exists) {
        conflicts.push({ path: operation.file.path, reason: 'target_changed_after_planning', currentHash: targetState.hash, owned: false });
      }
      continue;
    }
    if (!targetState.exists || targetState.hash !== operation.deployedHash) {
      conflicts.push({
        path: operation.file.path,
        reason: 'target_changed_after_planning',
        currentHash: targetState.hash || null,
        owned: Boolean(operation.previous),
      });
    }
  }
  return conflicts;
}

function pruneSnapshots(projectRoot, safeFs) {
  const snapshotBase = snapshotRootPath(projectRoot);
  let snapshots = listManagedSnapshots(snapshotBase);
  while (snapshots.length > RETAINED_SNAPSHOT_COUNT) {
    const oldest = snapshots.shift();
    const snapshotDir = targetPath(snapshotBase, oldest);
    assertNoSymlinkTree(snapshotDir);
    safeFs.removeTree(snapshotDirectoryRelativePath(oldest));
  }
  if (directoryBytes(snapshotBase) > SNAPSHOT_TOTAL_BYTE_CAP) {
    throw new Error(`runtime snapshot byte cap would be exceeded: ${SNAPSHOT_TOTAL_BYTE_CAP}`);
  }
}

function listManagedSnapshots(snapshotBase) {
  if (!lstatIfExists(snapshotBase)) return [];
  return fs.readdirSync(snapshotBase).filter(name => {
    if (!/^[A-Za-z0-9._-]+$/.test(name)) return false;
    const snapshotDir = targetPath(snapshotBase, name);
    const stat = lstatIfExists(snapshotDir);
    if (!stat || !stat.isDirectory()) return false;
    const manifest = targetPath(snapshotDir, 'manifest.json');
    const manifestStat = lstatIfExists(manifest);
    if (!manifestStat || !manifestStat.isFile()) return false;
    try {
      return JSON.parse(fs.readFileSync(manifest, 'utf8')).snapshotId === name;
    } catch (_) {
      return false;
    }
  }).sort();
}

function snapshotRootPath(projectRoot) {
  return targetPath(projectRoot, SNAPSHOT_ROOT);
}

function snapshotDirectoryPath(projectRoot, snapshotId) {
  if (!/^[A-Za-z0-9._-]+$/.test(String(snapshotId || ''))) throw new Error('invalid runtime snapshot id');
  return targetPath(snapshotRootPath(projectRoot), snapshotId);
}

function snapshotDirectoryRelativePath(snapshotId) {
  if (!/^[A-Za-z0-9._-]+$/.test(String(snapshotId || ''))) throw new Error('invalid runtime snapshot id');
  return path.posix.join(SNAPSHOT_ROOT, snapshotId);
}

function snapshotManifestRelativePath(snapshotId) {
  return path.posix.join(snapshotDirectoryRelativePath(snapshotId), 'manifest.json');
}

function snapshotFileRelativePath(snapshotId, filePath) {
  return path.posix.join(snapshotDirectoryRelativePath(snapshotId), 'files', normalizeRelativePath(filePath));
}

function collectSourceFiles(sourceRoot) {
  const mappings = Array.isArray(sourceRoot)
    ? sourceRoot
    : typeof sourceRoot === 'string'
      ? [{ source: sourceRoot, target: '' }]
      : sourceRoot && Array.isArray(sourceRoot.entries)
        ? sourceRoot.entries
        : [];
  const files = [];
  for (const mapping of mappings) {
    const source = path.resolve(mapping.source);
    const target = normalizeRelativePath(mapping.target || '');
    const stat = fs.statSync(source);
    if (stat.isFile()) {
      files.push({ source, path: target || path.basename(source) });
      continue;
    }
    if (!stat.isDirectory()) throw new Error(`managed source is not a file or directory: ${source}`);
    walkSource(source, source, target, files);
  }
  const duplicates = new Set();
  for (const file of files) {
    if (duplicates.has(file.path)) throw new Error(`duplicate managed target path: ${file.path}`);
    duplicates.add(file.path);
  }
  return files;
}

function walkSource(root, current, targetBase, files) {
  for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
    const source = path.join(current, entry.name);
    const relative = path.relative(root, source);
    if (entry.isDirectory()) {
      walkSource(root, source, targetBase, files);
    } else if (entry.isFile()) {
      files.push({ source, path: normalizeRelativePath(path.join(targetBase, relative)) });
    }
  }
}

function inspectTarget(root, relative) {
  const target = targetPath(root, relative);
  const stat = lstatIfExists(target);
  return { target, exists: Boolean(stat), stat, hash: stat ? hashFile(target) : null };
}

function conflictOperation(reason, file, target, deployedHash, previous) {
  return { action: 'conflict', reason, file, target, deployedHash, previous };
}

function operationDeletesTarget(operation) {
  return operation.action === 'delete' || (operation.action === 'conflict' && !operation.file.source);
}

function toConflict(operation) {
  return {
    path: operation.file.path,
    reason: operation.reason,
    currentHash: operation.deployedHash,
    owned: Boolean(operation.previous),
  };
}

function normalizeManifest(manifest) {
  if (!manifest || !Array.isArray(manifest.files)) return { schemaVersion: 1, bundleId: 'unknown', files: [] };
  return {
    schemaVersion: 1,
    bundleId: String(manifest.bundleId || 'unknown'),
    files: manifest.files.map(file => ({
      path: normalizeRelativePath(file.path),
      deployedHash: String(file.deployedHash || ''),
      sourceHash: String(file.sourceHash || ''),
      bundleId: String(file.bundleId || manifest.bundleId || 'unknown'),
    })).sort((left, right) => left.path.localeCompare(right.path)),
  };
}

function writeManifest(safeFs, manifest) {
  safeFs.writeFile(MANIFEST_NAME, Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`), 0o644);
}

function readSnapshot(projectRoot, snapshotId) {
  const snapshotDir = snapshotDirectoryPath(projectRoot, snapshotId);
  assertNoSymlinkTree(snapshotDir);
  return JSON.parse(fs.readFileSync(targetPath(snapshotDir, 'manifest.json'), 'utf8'));
}

function targetPath(root, relative) {
  const safeRelative = normalizeRelativePath(relative);
  const resolvedRoot = path.resolve(root);
  const target = path.resolve(resolvedRoot, safeRelative);
  if (target !== resolvedRoot && !target.startsWith(`${resolvedRoot}${path.sep}`)) throw new Error(`managed target escapes root: ${relative}`);
  assertNoSymlinkPath(resolvedRoot, target);
  return target;
}

function assertNoSymlinkPath(root, target) {
  const rootStat = lstatIfExists(root);
  if (rootStat && rootStat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${root}`);
  const relative = path.relative(root, target);
  if (!relative) return;
  let current = root;
  for (const segment of relative.split(path.sep)) {
    current = path.join(current, segment);
    const stat = lstatIfExists(current);
    if (!stat) break;
    if (stat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${current}`);
  }
}

function assertNoSymlinkTree(root) {
  const stat = lstatIfExists(root);
  if (!stat) return;
  if (stat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${root}`);
  if (!stat.isDirectory()) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const child = path.join(root, entry.name);
    const childStat = lstatIfExists(child);
    if (childStat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${child}`);
    if (childStat.isDirectory()) assertNoSymlinkTree(child);
  }
}

function lstatIfExists(file) {
  try {
    return fs.lstatSync(file);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function directoryBytes(root) {
  const stat = lstatIfExists(root);
  if (!stat) return 0;
  if (stat.isSymbolicLink()) throw new Error(`managed path contains symlink: ${root}`);
  if (stat.isFile()) return stat.size;
  let total = 0;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    total += directoryBytes(path.join(root, entry.name));
  }
  return total;
}

function normalizeRelativePath(value) {
  const normalized = path.posix.normalize(String(value || '').split(path.sep).join('/'));
  if (!normalized || normalized === '.' || normalized === '..' || normalized.startsWith('../') || path.posix.isAbsolute(normalized)) {
    if (!normalized || normalized === '.') return '';
    throw new Error(`invalid managed relative path: ${value}`);
  }
  return normalized;
}

function hashFile(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function nextSnapshotId(snapshotBase) {
  const stem = new Date().toISOString().replace(/[-:.]/g, '').replace('Z', 'Z');
  let candidate = stem;
  let suffix = 1;
  while (lstatIfExists(targetPath(snapshotBase, candidate))) candidate = `${stem}-${suffix++}`;
  return candidate;
}

function stableJson(value) {
  return JSON.stringify(value);
}

module.exports = {
  applyManagedSync,
  planManagedSync,
  rollbackManagedSync,
  RETAINED_SNAPSHOT_COUNT,
  SNAPSHOT_TOTAL_BYTE_CAP,
};
