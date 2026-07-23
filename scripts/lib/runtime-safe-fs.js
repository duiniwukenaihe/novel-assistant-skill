'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const BLOCKED_STATUS = 'blocked_runtime_safe_fs_unavailable';
const HELPER_VERSION = '1';
const SOURCE_PATH = path.join(__dirname, '..', 'native', 'novel-assistant-safe-fs-posix.c');

function blockedError() {
  const error = new Error('runtime safe filesystem is unavailable');
  error.code = BLOCKED_STATUS;
  return error;
}

function blockedRuntimeSafeFs() {
  const unavailable = () => {
    throw blockedError();
  };
  return {
    capability: { status: BLOCKED_STATUS },
    writeFile: unavailable,
    writeFileIfMissing: unavailable,
    copyFile: unavailable,
    deleteFile: unavailable,
    removeTree: unavailable,
  };
}

function selfTest(helperPath) {
  const result = childProcess.spawnSync(helperPath, ['--version'], {
    encoding: 'utf8',
    timeout: 5000,
  });
  return !result.error && result.status === 0 && result.stdout.trim() === HELPER_VERSION;
}

function cacheDirectory() {
  const userKey = typeof process.getuid === 'function' ? process.getuid() : 'user';
  return path.join(os.tmpdir(), `novel-assistant-safe-fs-${userKey}`);
}

function buildHelper() {
  if (!['darwin', 'linux'].includes(process.platform)) return null;
  if (process.env.NOVEL_ASSISTANT_SAFE_FS_DISABLE) return null;

  let source;
  try {
    source = fs.readFileSync(SOURCE_PATH);
  } catch (_error) {
    return null;
  }

  const hash = crypto.createHash('sha256').update(source).digest('hex');
  const cacheDir = cacheDirectory();
  const helperPath = path.join(cacheDir, `novel-assistant-safe-fs-posix-${hash}`);

  try {
    fs.mkdirSync(cacheDir, { recursive: true, mode: 0o700 });
    const cacheStat = fs.lstatSync(cacheDir);
    if (!cacheStat.isDirectory() || cacheStat.isSymbolicLink()) return null;
    fs.chmodSync(cacheDir, 0o700);

    if (fs.existsSync(helperPath)) {
      const helperStat = fs.lstatSync(helperPath);
      if (!helperStat.isFile() || helperStat.isSymbolicLink()) {
        fs.rmSync(helperPath, { force: true });
        return null;
      }
      if (selfTest(helperPath)) return helperPath;
      fs.rmSync(helperPath, { force: true });
      return null;
    }

    const temporaryPath = `${helperPath}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    try {
      const compiler = process.env.CC || 'cc';
      const result = childProcess.spawnSync(
        compiler,
        ['-std=c11', '-O2', '-Wall', '-Wextra', SOURCE_PATH, '-o', temporaryPath],
        { encoding: 'utf8', timeout: 30000 },
      );
      if (result.error || result.status !== 0) return null;
      const temporaryStat = fs.lstatSync(temporaryPath);
      if (!temporaryStat.isFile() || temporaryStat.isSymbolicLink()) return null;
      fs.chmodSync(temporaryPath, 0o700);
      if (!selfTest(temporaryPath)) return null;
      fs.renameSync(temporaryPath, helperPath);
      return helperPath;
    } finally {
      fs.rmSync(temporaryPath, { force: true });
    }
  } catch (_error) {
    return null;
  }
}

function validateRelativePath(relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || relativePath.startsWith('/')) {
    throw new Error('invalid project-relative path for safe filesystem');
  }
  const components = relativePath.split('/');
  if (components.some(component => component === '' || component === '.' || component === '..')) {
    throw new Error('invalid project-relative path for safe filesystem');
  }
}

function validateMode(mode) {
  if (!Number.isInteger(mode) || mode < 0 || mode > 0o777) {
    throw new Error('invalid file mode for safe filesystem');
  }
  return mode.toString(8);
}

function runHelper(helperPath, args) {
  const result = childProcess.spawnSync(helperPath, args, {
    encoding: 'utf8',
    timeout: 30000,
  });
  if (!result.error && result.status === 0) return;

  const detail = result.stderr && result.stderr.trim()
    ? result.stderr.trim()
    : result.error
      ? result.error.message
      : `helper exited with status ${result.status}`;
  const error = new Error(`safe filesystem operation failed: ${detail}`);
  error.code = 'runtime_safe_fs_operation_failed';
  throw error;
}

function helperAcceptsRoot(helperPath, root) {
  const result = childProcess.spawnSync(helperPath, ['root-preflight', root], {
    encoding: 'utf8',
    timeout: 5000,
  });
  return !result.error && result.status === 0;
}

function isInsideProject(projectRoot, candidate) {
  const relative = path.relative(projectRoot, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function createExternalTempDirectory(projectRoot) {
  const candidates = [os.tmpdir(), os.homedir(), path.dirname(projectRoot)];
  for (const candidate of candidates) {
    if (!candidate || isInsideProject(projectRoot, candidate)) continue;
    try {
      return fs.mkdtempSync(path.join(candidate, '.novel-assistant-safe-fs-source-'));
    } catch (_error) {
      // Try the next writable location outside the project.
    }
  }
  throw new Error('safe filesystem cannot create an outside-project temporary source');
}

function createRuntimeSafeFs(projectRoot) {
  const helperPath = buildHelper();
  if (!helperPath) return blockedRuntimeSafeFs();

  const root = path.resolve(projectRoot);
  if (!helperAcceptsRoot(helperPath, root)) return blockedRuntimeSafeFs();
  const capability = { status: 'ready' };

  function writeBuffer(command, relativePath, buffer, mode) {
    validateRelativePath(relativePath);
    if (!Buffer.isBuffer(buffer)) throw new TypeError('safe filesystem write buffer must be a Buffer');
    const modeText = validateMode(mode);
    const temporaryDirectory = createExternalTempDirectory(root);
    const sourcePath = path.join(temporaryDirectory, 'source');
    let sourceFd = -1;
    try {
      sourceFd = fs.openSync(
        sourcePath,
        fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
        0o600,
      );
      fs.writeFileSync(sourceFd, buffer);
      fs.fsyncSync(sourceFd);
      fs.closeSync(sourceFd);
      sourceFd = -1;
      runHelper(helperPath, [command, root, relativePath, sourcePath, modeText]);
    } finally {
      if (sourceFd >= 0) fs.closeSync(sourceFd);
      fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  }

  return {
    capability,

    writeFile(relativePath, buffer, mode) {
      writeBuffer('external-copy', relativePath, buffer, mode);
    },

    writeFileIfMissing(relativePath, buffer, mode) {
      writeBuffer('external-copy-if-missing', relativePath, buffer, mode);
    },

    copyFile(sourceRelativePath, targetRelativePath, mode) {
      validateRelativePath(sourceRelativePath);
      validateRelativePath(targetRelativePath);
      runHelper(helperPath, [
        'copy-file',
        root,
        sourceRelativePath,
        targetRelativePath,
        validateMode(mode),
      ]);
    },

    deleteFile(relativePath) {
      validateRelativePath(relativePath);
      runHelper(helperPath, ['delete-file', root, relativePath]);
    },

    removeTree(relativePath) {
      validateRelativePath(relativePath);
      runHelper(helperPath, ['remove-tree', root, relativePath]);
    },
  };
}

module.exports = {
  createRuntimeSafeFs,
};
