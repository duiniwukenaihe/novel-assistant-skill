#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const HOSTS = Object.freeze({
  claude: ['~/.claude/skills/novel-assistant'],
  codex: ['~/.codex/skills/novel-assistant', '<project>/.agents/skills/novel-assistant'],
  zcode: ['~/.zcode/skills/novel-assistant'],
  opencode: ['<project>/.opencode/skills/novel-assistant', '~/.config/opencode/skills/novel-assistant'],
  openclaw: ['<workspace>/skills/novel-assistant'],
});

const REQUIRED_FILES = Object.freeze([
  'SKILL.md',
  'novel-assistant-manifest.json',
  'references/internal-skills/story/SKILL.md',
  'references/internal-skills/story-workflow/SKILL.md',
  'scripts/workflow-state-machine.js',
  'scripts/novel-assistant-update-check.js',
  'scripts/short-writing-profile.js',
  'scripts/check-host-skill-discovery.js',
]);

function parseArgs(argv) {
  const options = { json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (item === '--bundle') options.bundle = argv[++index];
    else if (item === '--host') options.host = argv[++index];
    else if (item === '--json') options.json = true;
    else throw new Error(`Unknown argument: ${item}`);
  }
  if (!options.bundle || !options.host) {
    throw new Error('Usage: check-host-skill-discovery.js --bundle <dir> --host <name> [--json]');
  }
  return options;
}

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function checkRegularFile(bundleReal, relativePath) {
  const target = path.join(bundleReal, relativePath);
  try {
    const stat = fs.lstatSync(target);
    if (stat.isSymbolicLink()) {
      return { id: relativePath, status: 'fail', error_code: 'symlink_not_allowed' };
    }
    if (!stat.isFile()) {
      return { id: relativePath, status: 'fail', error_code: 'not_a_regular_file' };
    }
    const real = fs.realpathSync(target);
    if (!inside(bundleReal, real)) {
      return { id: relativePath, status: 'fail', error_code: 'path_escape' };
    }
    return { id: relativePath, status: 'pass' };
  } catch (error) {
    return { id: relativePath, status: 'fail', error_code: 'missing_required_file', message: error.message };
  }
}

function inspectBundle(bundle, host) {
  const root = path.resolve(bundle);
  let bundleReal = root;
  const checks = [];
  try {
    const rootStat = fs.lstatSync(root);
    if (rootStat.isSymbolicLink()) {
      checks.push({ id: 'bundle_root', status: 'fail', error_code: 'symlink_not_allowed' });
    } else if (!rootStat.isDirectory()) {
      checks.push({ id: 'bundle_root', status: 'fail', error_code: 'not_a_directory' });
    } else {
      bundleReal = fs.realpathSync(root);
      checks.push({ id: 'bundle_root', status: 'pass' });
    }
  } catch (error) {
    checks.push({ id: 'bundle_root', status: 'fail', error_code: 'missing_bundle', message: error.message });
  }

  if (checks[0].status === 'pass') {
    for (const required of REQUIRED_FILES) checks.push(checkRegularFile(bundleReal, required));

    try {
      const manifest = JSON.parse(fs.readFileSync(path.join(bundleReal, 'novel-assistant-manifest.json'), 'utf8'));
      checks.push(manifest.bundleName === 'novel-assistant' && /^bundle-/.test(manifest.bundleId || '')
        ? { id: 'manifest_identity', status: 'pass' }
        : { id: 'manifest_identity', status: 'fail', error_code: 'invalid_manifest_identity' });
    } catch (error) {
      checks.push({ id: 'manifest_identity', status: 'fail', error_code: 'invalid_manifest_json', message: error.message });
    }

    try {
      const skill = fs.readFileSync(path.join(bundleReal, 'SKILL.md'), 'utf8');
      const frontmatter = skill.match(/^---\r?\n([\s\S]*?)\r?\n---/);
      checks.push(frontmatter && /^name:\s*novel-assistant\s*$/m.test(frontmatter[1])
        ? { id: 'skill_frontmatter', status: 'pass' }
        : { id: 'skill_frontmatter', status: 'fail', error_code: 'invalid_skill_frontmatter' });
    } catch (error) {
      checks.push({ id: 'skill_frontmatter', status: 'fail', error_code: 'unreadable_skill', message: error.message });
    }
  }

  return {
    schemaVersion: '1.0.0',
    status: checks.every(item => item.status === 'pass') ? 'pass' : 'fail',
    host,
    discovery_mode: 'static_read_only',
    bundle: root,
    expected_discovery_paths: HOSTS[host],
    checks,
    mutations: [],
  };
}

function print(result, json) {
  process.stdout.write(`${JSON.stringify(result, null, json ? 2 : 0)}\n`);
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    print({ schemaVersion: '1.0.0', status: 'error', error_code: 'invalid_arguments', message: error.message, mutations: [] }, true);
    process.exitCode = 2;
    return;
  }

  if (!Object.prototype.hasOwnProperty.call(HOSTS, options.host)) {
    print({ schemaVersion: '1.0.0', status: 'error', error_code: 'unsupported_host', host: options.host, supported_hosts: Object.keys(HOSTS), mutations: [] }, options.json);
    process.exitCode = 2;
    return;
  }

  const result = inspectBundle(options.bundle, options.host);
  print(result, options.json);
  process.exitCode = result.status === 'pass' ? 0 : 1;
}

if (require.main === module) main();

module.exports = { inspectBundle };
