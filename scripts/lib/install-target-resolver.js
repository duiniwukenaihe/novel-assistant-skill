#!/usr/bin/env node
'use strict';

// scripts/lib/install-target-resolver.js
//
// Single source of truth for which host skills directories novel-assistant
// should install to. Used by both local install (`na-dev install-local-private`)
// and the self-update channel so the two cannot drift.
//
// Required hosts: claude, codex, zcode. opencode is opt-in only: callers must
// explicitly pass { opencode: true } or { includeOpencode: true } to add it.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const REQUIRED_HOSTS = Object.freeze(['claude', 'codex', 'zcode']);
const OPTIONAL_HOSTS = Object.freeze(['opencode']);

function homeRoot(options = {}) {
  const explicit = String(options.home || options.installRoot || '').trim();
  if (explicit) return path.resolve(explicit);
  return process.env.HOME || os.homedir() || '';
}

function defaultTarget(host, options = {}) {
  const home = homeRoot(options);
  if (!home) return '';
  return path.join(home, `.${host}`, 'skills', 'novel-assistant');
}

function requiredHosts() {
  return [...REQUIRED_HOSTS];
}

function optionalHosts() {
  return [...OPTIONAL_HOSTS];
}

function resolveInstallTargets(options = {}) {
  const out = [];
  const seen = new Set();
  const includeOpencode = options.opencode === true
    || options.includeOpencode === true
    || options.opencode === 'true'
    || options.includeOpencode === 'true';

  for (const host of REQUIRED_HOSTS) {
    const target = options.targets && options.targets[host]
      ? path.resolve(options.targets[host])
      : defaultTarget(host, options);
    if (target && !seen.has(target)) {
      seen.add(target);
      out.push(target);
    }
  }

  if (includeOpencode) {
    const target = options.targets && options.targets.opencode
      ? path.resolve(options.targets.opencode)
      : defaultTarget('opencode', options);
    if (target && !seen.has(target)) {
      seen.add(target);
      out.push(target);
    }
  }

  return out;
}

function targetHost(targetPath) {
  const normalized = String(targetPath || '');
  for (const host of [...REQUIRED_HOSTS, ...OPTIONAL_HOSTS]) {
    if (normalized.includes(`.${host}/skills/novel-assistant`)) return host;
    if (normalized.includes(`.${host}\\skills\\novel-assistant`)) return host;
  }
  return null;
}

function isPathSafe(value) {
  if (typeof value !== 'string' || !value) return false;
  if (path.isAbsolute(value)) return true;
  if (value.startsWith('~/')) return true;
  return false;
}

function loadManifest(target) {
  const manifestPath = path.join(target, 'novel-assistant-manifest.json');
  if (!fs.existsSync(manifestPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (_error) {
    return null;
  }
}

function walkFiles(root, base = '') {
  const directory = path.join(root, base);
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const relative = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) return walkFiles(root, relative);
    return entry.isFile() ? [relative] : [];
  }).sort();
}

function fileDigest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function verifyBundleTarget(source, target) {
  const sourceManifest = loadManifest(source);
  const targetManifest = loadManifest(target);
  const findings = [];
  if (!sourceManifest) findings.push({ id: 'missing_source_manifest', target: source });
  if (!targetManifest) findings.push({ id: 'missing_target_manifest', target });
  if (sourceManifest && targetManifest) {
    for (const key of ['bundleId', 'sourceTreeId', 'sourceInputDigest']) {
      if (String(sourceManifest[key] || '') !== String(targetManifest[key] || '')) {
        findings.push({ id: 'manifest_identity_mismatch', key });
      }
    }
  }
  const sourceFiles = walkFiles(source);
  const targetFiles = walkFiles(target);
  const targetSet = new Set(targetFiles);
  for (const relative of sourceFiles) {
    if (!targetSet.has(relative)) {
      findings.push({ id: 'missing_target_file', target: relative });
      continue;
    }
    if (fileDigest(path.join(source, relative)) !== fileDigest(path.join(target, relative))) {
      findings.push({ id: 'target_file_digest_mismatch', target: relative });
    }
  }
  const sourceSet = new Set(sourceFiles);
  for (const relative of targetFiles) {
    if (!sourceSet.has(relative)) findings.push({ id: 'unexpected_target_file', target: relative });
  }
  return { ok: findings.length === 0, findings, sourceFiles: sourceFiles.length, targetFiles: targetFiles.length };
}

function verifyRuntimeTarget(target, profile) {
  const expectedProfile = String(profile || 'private');
  const findings = [];
  const script = path.join(target, 'scripts', 'workflow-state-machine.js');
  if (!fs.existsSync(script)) {
    return { ok: false, findings: [{ id: 'missing_runtime_workflow_state_machine', target: script }] };
  }
  const templateArgs = [script, 'templates'];
  if (expectedProfile === 'public') templateArgs.push('--no-private-registry');
  templateArgs.push('--json');
  const result = spawnSync(process.execPath, templateArgs, {
    cwd: target,
    encoding: 'utf8',
  });
  let templates = null;
  try { templates = JSON.parse(result.stdout || ''); } catch (_error) { /* handled below */ }
  if (result.status !== 0 || !templates) {
    return {
      ok: false,
      findings: [{ id: 'runtime_workflow_templates_invalid', target: script, exitCode: result.status }],
    };
  }
  const registryCount = Number(templates.privateRegistryCount || 0);
  const definitions = Array.isArray(templates.templates) ? templates.templates : [];
  const hasPrivateStartup = definitions.some((item) => String((item || {}).workflow_type || '') === 'private_short_startup');
  if (expectedProfile === 'private') {
    if (registryCount <= 0) findings.push({ id: 'private_runtime_registry_missing' });
    if (!hasPrivateStartup) findings.push({ id: 'private_runtime_startup_missing' });
  } else if (expectedProfile === 'public') {
    if (registryCount !== 0) findings.push({ id: 'public_runtime_registry_present', actual: registryCount });
    if (hasPrivateStartup) findings.push({ id: 'public_runtime_private_startup_present' });
    if (fs.existsSync(path.join(target, 'references', 'private-internal-skills'))) {
      findings.push({ id: 'public_runtime_private_assets_present' });
    }
  } else {
    findings.push({ id: 'unknown_runtime_profile', profile: expectedProfile });
  }
  return { ok: findings.length === 0, findings, privateRegistryCount: registryCount, hasPrivateStartup };
}

module.exports = {
  REQUIRED_HOSTS,
  OPTIONAL_HOSTS,
  requiredHosts,
  optionalHosts,
  resolveInstallTargets,
  targetHost,
  isPathSafe,
  loadManifest,
  verifyBundleTarget,
  verifyRuntimeTarget,
};
