#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function privateModuleRoots(moduleName, options = {}) {
  const scriptRoot = path.resolve(options.scriptRoot || path.join(__dirname, '..', '..'));
  const projectRoot = path.resolve(options.projectRoot || process.cwd());
  const envSkillDir = String(process.env.NOVEL_ASSISTANT_SKILL_DIR || '').trim();
  const hostOrder = orderedHosts(projectRoot);
  const candidates = [
    options.extraRoot,
    envSkillDir ? path.join(envSkillDir, 'references', 'private-internal-skills', moduleName) : '',
    path.join(scriptRoot, 'src', 'private-internal-skills', moduleName),
    path.join(scriptRoot, 'skills', 'novel-assistant', 'references', 'private-internal-skills', moduleName),
    path.join(scriptRoot, 'references', 'private-internal-skills', moduleName),
    ...hostOrder.map(host => path.join(os.homedir(), `.${host}`, 'skills', 'novel-assistant', 'references', 'private-internal-skills', moduleName)),
  ].filter(Boolean).map(item => path.resolve(item));
  return Array.from(new Set(candidates));
}

function resolvePrivateModule(moduleName, requiredPaths, options = {}) {
  const required = Array.isArray(requiredPaths) ? requiredPaths : [];
  for (const root of privateModuleRoots(moduleName, options)) {
    if (required.every(relative => isFile(path.join(root, relative)))) return root;
  }
  return '';
}

function orderedHosts(projectRoot) {
  const declared = readTargetCli(projectRoot);
  const preferred = declared === 'claude-code'
    ? 'claude'
    : declared === 'codex' || declared === 'zcode' ? declared : '';
  return Array.from(new Set([preferred, 'claude', 'codex', 'zcode'].filter(Boolean)));
}

function readTargetCli(projectRoot) {
  const sentinel = path.join(projectRoot, '.story-deployed');
  if (!isFile(sentinel)) return '';
  const match = fs.readFileSync(sentinel, 'utf8').match(/^target_cli:\s*(\S+)\s*$/m);
  return match ? String(match[1] || '').trim() : '';
}

function isFile(file) {
  return fs.existsSync(file) && fs.statSync(file).isFile();
}

module.exports = {
  privateModuleRoots,
  resolvePrivateModule,
};
