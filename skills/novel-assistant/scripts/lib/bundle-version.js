#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const BUNDLE_FILE_MANIFEST = path.join('config', 'novel-assistant-bundle-files.json');

function loadBundleFileManifest(root) {
  const manifestPath = path.join(root, BUNDLE_FILE_MANIFEST);
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(`could not read bundle file manifest: ${manifestPath}: ${error.message}`);
  }
  if (!manifest || manifest.schemaVersion !== 1 || typeof manifest.bundleName !== 'string' || !manifest.bundleName) {
    throw new Error(`invalid bundle file manifest: ${manifestPath}`);
  }
  for (const field of ['internalSkills', 'scriptFiles', 'scriptDirectories']) {
    if (!Array.isArray(manifest[field]) || manifest[field].some((value) => typeof value !== 'string' || !value || value.includes('/') || value.includes('\\'))) {
      throw new Error(`invalid ${field} in bundle file manifest: ${manifestPath}`);
    }
  }
  return manifest;
}

function listFiles(root) {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(root, entry.name);
    if (entry.isDirectory()) return listFiles(file);
    return entry.isFile() ? [file] : [];
  });
}

function comparePosixUtf8(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function sortEntries(entries) {
  return [...entries].sort((left, right) => comparePosixUtf8(left.destination, right.destination));
}

function hashEntriesDigest(entries) {
  const hash = crypto.createHash('sha256');
  for (const entry of sortEntries(entries)) {
    hash.update(entry.destination);
    hash.update('\0');
    hash.update(fs.readFileSync(entry.source));
    hash.update('\0');
  }
  return hash.digest('hex');
}

function hashEntries(entries) {
  return hashEntriesDigest(entries).slice(0, 12);
}

function entriesForTree(root, destinationRoot) {
  return listFiles(root).map((source) => ({
    source,
    destination: path.posix.join(destinationRoot, path.relative(root, source).split(path.sep).join('/')),
  }));
}

function readPrivateSkillNames(privateRoot, includePrivate) {
  if (!includePrivate) return [];
  if (!fs.existsSync(privateRoot)) return [];
  return fs.readdirSync(privateRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && fs.existsSync(path.join(privateRoot, entry.name, 'SKILL.md')))
    .map((entry) => entry.name)
    .sort(comparePosixUtf8);
}

function buildSourceLayout(repoRoot, options = {}) {
  const includePrivate = options.includePrivate !== false;
  return {
    includePrivate,
    sourceSkillsDir: path.resolve(options.sourceSkillsDir || path.join(repoRoot, 'src', 'internal-skills')),
    privateSourceSkillsDir: includePrivate
      ? path.resolve(options.privateSourceSkillsDir || path.join(repoRoot, 'src', 'private-internal-skills'))
      : null,
  };
}

function repoRelativePath(repoRoot, candidate) {
  let resolvedRepoRoot;
  let resolvedCandidate;
  try {
    resolvedRepoRoot = fs.realpathSync(repoRoot);
    resolvedCandidate = fs.realpathSync(candidate);
    if (!fs.statSync(resolvedCandidate).isDirectory()) return null;
  } catch (_error) {
    return null;
  }
  const relative = path.relative(resolvedRepoRoot, resolvedCandidate);
  if (!relative || relative === '.' || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    return null;
  }
  return relative.split(path.sep).join('/');
}

function manifestSourceLayout(repoRoot, layout) {
  const sourceSkillsDir = repoRelativePath(repoRoot, layout.sourceSkillsDir);
  const privateSourceSkillsDir = layout.includePrivate
    ? repoRelativePath(repoRoot, layout.privateSourceSkillsDir)
    : null;
  const recomputable = Boolean(sourceSkillsDir && (!layout.includePrivate || privateSourceSkillsDir));
  return {
    schemaVersion: 1,
    includePrivate: Boolean(layout.includePrivate),
    sourceSkillsDir,
    privateSourceSkillsDir,
    recomputable,
  };
}

function safeManifestDirectory(repoRoot, relativePath) {
  if (typeof relativePath !== 'string' || !relativePath) return null;
  if (path.posix.isAbsolute(relativePath) || path.win32.isAbsolute(relativePath)) return null;
  const segments = relativePath.split('/');
  if (segments.some((segment) => !segment || segment === '.' || segment === '..')) return null;
  const resolved = path.resolve(repoRoot, ...segments);
  return repoRelativePath(repoRoot, resolved) === relativePath && fs.existsSync(resolved)
    && fs.statSync(resolved).isDirectory()
    ? resolved
    : null;
}

function resolveManifestSourceLayout(repoRoot, layout) {
  if (!layout || layout.schemaVersion !== 1 || layout.recomputable !== true || typeof layout.includePrivate !== 'boolean') {
    return null;
  }
  const sourceSkillsDir = safeManifestDirectory(repoRoot, layout.sourceSkillsDir);
  if (!sourceSkillsDir) return null;
  if (!layout.includePrivate) return buildSourceLayout(repoRoot, { includePrivate: false, sourceSkillsDir });
  const privateSourceSkillsDir = safeManifestDirectory(repoRoot, layout.privateSourceSkillsDir);
  if (!privateSourceSkillsDir) return null;
  return buildSourceLayout(repoRoot, { includePrivate: true, sourceSkillsDir, privateSourceSkillsDir });
}

function sourceEntries(repoRoot, bundleName, layout) {
  const fileManifest = loadBundleFileManifest(repoRoot);
  const entries = [{
    source: path.join(repoRoot, 'skills', bundleName, 'SKILL.md'),
    destination: 'SKILL.md',
  }];
  entries.push({
    source: path.join(repoRoot, BUNDLE_FILE_MANIFEST),
    destination: BUNDLE_FILE_MANIFEST,
  });
  for (const name of fileManifest.internalSkills) {
    entries.push(...entriesForTree(
      path.join(layout.sourceSkillsDir, name),
      `references/internal-skills/${name}`,
    ));
  }
  for (const name of readPrivateSkillNames(layout.privateSourceSkillsDir, layout.includePrivate)) {
    entries.push(...entriesForTree(
      path.join(layout.privateSourceSkillsDir, name),
      `references/private-internal-skills/${name}`,
    ));
  }
  for (const name of fileManifest.scriptFiles) {
    entries.push({
      source: path.join(repoRoot, 'scripts', name),
      destination: `scripts/${name}`,
    });
  }
  for (const directory of fileManifest.scriptDirectories) {
    entries.push(...entriesForTree(path.join(repoRoot, 'scripts', directory), `scripts/${directory}`));
  }
  return entries;
}

function bundleEntries(bundleDir) {
  const entries = [{ source: path.join(bundleDir, 'SKILL.md'), destination: 'SKILL.md' }];
  entries.push(...entriesForTree(path.join(bundleDir, 'references', 'internal-skills'), 'references/internal-skills'));
  entries.push(...entriesForTree(path.join(bundleDir, 'references', 'private-internal-skills'), 'references/private-internal-skills'));
  entries.push(...entriesForTree(path.join(bundleDir, 'scripts'), 'scripts'));
  entries.push(...entriesForTree(path.join(bundleDir, 'config'), 'config'));
  return entries;
}

function ensureEntries(entries) {
  const missing = entries.filter(({ source }) => !fs.existsSync(source));
  if (missing.length) throw new Error(`missing version input: ${missing[0].source}`);
  return entries;
}

function computeSourceTreeId(repoRoot, bundleName, layoutOrIncludePrivate = true) {
  return `tree-${computeSourceInputDigest(repoRoot, bundleName, layoutOrIncludePrivate).slice('sha256:'.length, 'sha256:'.length + 12)}`;
}

function computeSourceInputDigest(repoRoot, bundleName, layoutOrIncludePrivate = true) {
  const layout = typeof layoutOrIncludePrivate === 'boolean'
    ? buildSourceLayout(repoRoot, { includePrivate: layoutOrIncludePrivate })
    : buildSourceLayout(repoRoot, layoutOrIncludePrivate);
  return `sha256:${hashEntriesDigest(ensureEntries(sourceEntries(repoRoot, bundleName, layout)))}`;
}

function computeManifestSourceTreeId(repoRoot, bundleName, manifestLayout) {
  const layout = resolveManifestSourceLayout(repoRoot, manifestLayout);
  if (!layout) return null;
  try {
    return computeSourceTreeId(repoRoot, bundleName, layout);
  } catch (_error) {
    return null;
  }
}

function computeManifestSourceInputDigest(repoRoot, bundleName, manifestLayout) {
  const layout = resolveManifestSourceLayout(repoRoot, manifestLayout);
  if (!layout) return null;
  try {
    return computeSourceInputDigest(repoRoot, bundleName, layout);
  } catch (_error) {
    return null;
  }
}

function computeBundleId(bundleDir) {
  return `bundle-${hashEntries(ensureEntries(bundleEntries(bundleDir)))}`;
}

function findRepositoryRoot(manifestPath, bundleName) {
  const bundleDir = path.dirname(path.resolve(manifestPath));
  let cursor = bundleDir;
  while (cursor !== path.dirname(cursor)) {
    const expectedBundle = path.join(cursor, 'skills', bundleName);
    if (
      path.resolve(expectedBundle) === bundleDir
      && fs.existsSync(path.join(cursor, 'src', 'internal-skills'))
    ) return cursor;
    cursor = path.dirname(cursor);
  }
  return null;
}

function gitValue(repoRoot, args) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8', shell: false });
  return result.status === 0 ? result.stdout.trim() : '';
}

function sourceState(repoRoot) {
  return gitValue(repoRoot, ['status', '--porcelain']) ? 'dirty' : 'clean';
}

function bundleInputMatchers(repoRoot, bundleName, layoutOrIncludePrivate = true) {
  const layout = typeof layoutOrIncludePrivate === 'boolean'
    ? buildSourceLayout(repoRoot, { includePrivate: layoutOrIncludePrivate })
    : buildSourceLayout(repoRoot, layoutOrIncludePrivate);
  const exactPaths = new Set();
  const directoryPrefixes = new Set();
  for (const entry of ensureEntries(sourceEntries(repoRoot, bundleName, layout))) {
    const relative = path.relative(repoRoot, entry.source).split(path.sep).join('/');
    exactPaths.add(relative);
  }
  directoryPrefixes.add('src/internal-skills/');
  if (layout.includePrivate) directoryPrefixes.add('src/private-internal-skills/');
  directoryPrefixes.add('scripts/lib/');
  directoryPrefixes.add('scripts/native/');
  return { exactPaths, directoryPrefixes };
}

function releaseSourceState(repoRoot, bundleName, layoutOrIncludePrivate = true) {
  const result = spawnSync('git', ['status', '--porcelain', '-z', '--untracked-files=all'], {
    cwd: repoRoot,
    encoding: 'utf8',
    shell: false,
  });
  if (result.status !== 0) return sourceState(repoRoot);
  const paths = parsePorcelainPaths(result.stdout || '');
  let matchers;
  try {
    matchers = bundleInputMatchers(repoRoot, bundleName, layoutOrIncludePrivate);
  } catch (_error) {
    return sourceState(repoRoot);
  }
  const hasSourceChange = paths.some((file) => matchers.exactPaths.has(file)
    || [...matchers.directoryPrefixes].some((prefix) => file.startsWith(prefix)));
  return hasSourceChange ? 'dirty' : 'clean';
}

function parsePorcelainPaths(output) {
  const records = String(output || '').split('\0');
  const paths = [];
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (!record || record.length < 4) continue;
    const status = record.slice(0, 2);
    paths.push(record.slice(3));
    if (status.includes('R') || status.includes('C')) {
      const original = records[index + 1];
      if (original) paths.push(original);
      index += 1;
    }
  }
  return paths;
}

function sourceCommit(repoRoot) {
  return gitValue(repoRoot, ['rev-parse', '--short', 'HEAD']);
}

function parseCli(argv) {
  const args = {
    repoRoot: '',
    bundleDir: '',
    bundleName: 'novel-assistant',
    includePrivate: true,
    sourceSkillsDir: '',
    privateSourceSkillsDir: '',
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--repo-root') args.repoRoot = path.resolve(argv[++index] || '');
    else if (arg === '--bundle-dir') args.bundleDir = path.resolve(argv[++index] || '');
    else if (arg === '--bundle-name') args.bundleName = argv[++index] || args.bundleName;
    else if (arg === '--include-private') args.includePrivate = argv[++index] !== '0';
    else if (arg === '--source-skills-dir') args.sourceSkillsDir = argv[++index] || '';
    else if (arg === '--private-source-skills-dir') args.privateSourceSkillsDir = argv[++index] || '';
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

if (require.main === module) {
  try {
    const args = parseCli(process.argv.slice(2));
    const layout = buildSourceLayout(args.repoRoot, args);
    process.stdout.write(`${JSON.stringify({
      bundleId: computeBundleId(args.bundleDir),
      sourceTreeId: computeSourceTreeId(args.repoRoot, args.bundleName, layout),
      sourceInputDigest: computeSourceInputDigest(args.repoRoot, args.bundleName, layout),
      sourceLayout: manifestSourceLayout(args.repoRoot, layout),
    })}\n`);
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}

module.exports = {
  buildSourceLayout,
  computeBundleId,
  computeManifestSourceInputDigest,
  computeManifestSourceTreeId,
  computeSourceInputDigest,
  computeSourceTreeId,
  findRepositoryRoot,
  hashEntries,
  hashEntriesDigest,
  loadBundleFileManifest,
  manifestSourceLayout,
  bundleInputMatchers,
  resolveManifestSourceLayout,
  sortEntries,
  sourceCommit,
  sourceEntries,
  releaseSourceState,
  sourceState,
};
