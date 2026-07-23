#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { loadBundleFileManifest } = require('./lib/bundle-version');
const { resolveProjectRoot } = require('./lib/project-root-resolver');
const { applyManagedSync, planManagedSync } = require('./lib/runtime-managed-files');
const { createRuntimeSafeFs } = require('./lib/runtime-safe-fs');

const USAGE = `Usage: node scripts/novel-assistant-sync-runtime.js [--project-root .] [--skill-dir /absolute/novel-assistant] [--dry-run] [--confirm-conflicts] [--json]

Synchronize only the writing collaboration runtime:
  hooks, rules, agents, agent references, runtime scripts, write policy and .story-deployed.

It never moves or rewrites prose, outline, chapter detail, setting, tracking ledgers,
or migration targets. It only initializes missing write-policy metadata. Layout migration
remains a separate confirmed action.`;

const args = parseArgs(process.argv);
if (!args.projectRoot) args.projectRoot = '.';

const rootResolution = resolveProjectRoot({ cwd: process.cwd(), explicitBookRoot: args.projectRoot });
if (rootResolution.status !== 'resolved' || rootResolution.root_kind !== 'book') rejectRootResolution(rootResolution);

const projectRoot = rootResolution.book_root;
const managedProjectRoot = descriptorSafeProjectRoot(projectRoot);
const skillDir = resolveSkillDirectory(args.skillDir);
const bundleFileManifest = loadBundleFileManifest(skillDir);
// Managed runtime anchors: workflow-runner.js, workflow-supervisor.js,
// workflow-session-heartbeat.js. The actual synchronized file list is
// manifest-driven through bundleFileManifest.scriptFiles.
const SCRIPT_NAMES = bundleFileManifest.scriptFiles;
const setupDir = path.join(skillDir, 'references', 'internal-skills', 'story-setup');
const templatesDir = path.join(setupDir, 'references', 'templates');
const manifestPath = path.join(skillDir, 'novel-assistant-manifest.json');
const manifest = readJsonIfExists(manifestPath) || {};

assertDirectory(projectRoot, 'project root');
assertDirectory(skillDir, 'novel-assistant skill dir');
assertDirectory(setupDir, 'story-setup internal skill dir');

const managedPlan = buildManagedPlan();
const plan = buildPlan(managedPlan);
const plannedConfirmationRequired = managedPlan.conflicts.length > 0 && (!args.confirmConflicts || args.dryRun);
let managedApplyResult = null;
let runtimeSafeFs = null;

if (!args.dryRun && !plannedConfirmationRequired) {
  runtimeSafeFs = createRuntimeSafeFs(managedProjectRoot);
  managedApplyResult = runtimeSafeFs.capability.status === 'ready'
    ? applyPlan(plan, runtimeSafeFs)
    : {
      status: 'blocked_runtime_safe_fs_unavailable',
      changed: 0,
      conflicts: managedPlan.conflicts,
      runtime_safe_fs: runtimeSafeFs.capability,
    };
}

const blockedRuntimeSafeFs = managedApplyResult && managedApplyResult.status === 'blocked_runtime_safe_fs_unavailable';
const confirmationRequired = plannedConfirmationRequired
  || (managedApplyResult && managedApplyResult.status === 'confirmation_required');

const result = {
  status: blockedRuntimeSafeFs
    ? 'blocked_runtime_safe_fs_unavailable'
    : confirmationRequired
      ? 'confirmation_required'
      : 'synced',
  dryRun: args.dryRun,
  projectRoot,
  root_resolution: rootResolution,
  skillDir,
  bundleId: manifest.bundleId || 'unknown',
  sourceCommit: manifest.sourceCommit || 'unknown',
  agentsVersion: Number(manifest.agentsVersion || 18),
  setupSkillVersion: String(manifest.setupSkillVersion || '1.4.5'),
  copied: managedPreviewItems().concat(plan.filter(item => item.type !== 'managed-files')).map(item => ({
    type: item.type,
    target: path.relative(projectRoot, item.target),
    count: item.count || 1,
  })),
  conflicts: managedApplyResult && Array.isArray(managedApplyResult.conflicts)
    ? managedApplyResult.conflicts
    : managedPlan.conflicts,
  runtime_safe_fs: managedApplyResult && managedApplyResult.runtime_safe_fs
    ? managedApplyResult.runtime_safe_fs
    : { status: 'not_checked' },
  writePolicy: effectiveWritePolicy(plan.find(item => item.type === 'write-policy')),
  protectedContent: ['正文', '大纲', '细纲', '设定', '追踪正文资产'],
};

if (args.json) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else if (blockedRuntimeSafeFs) {
  process.stdout.write([
    'novel-assistant writing collaboration runtime blocked',
    `project: ${projectRoot}`,
    `status: ${result.status}`,
    '',
  ].join('\n'));
} else {
  process.stdout.write([
    'novel-assistant writing collaboration runtime synced',
    `project: ${projectRoot}`,
    `bundle: ${result.bundleId}`,
    `operations: ${plan.length}`,
    'protected: prose, outlines, chapter details, settings and tracking content were not migrated',
    '',
  ].join('\n'));
}

if ((blockedRuntimeSafeFs || confirmationRequired) && !args.dryRun) process.exitCode = 2;

function parseArgs(argv) {
  const parsed = { projectRoot: '', skillDir: '', dryRun: false, confirmConflicts: false, json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') {
      parsed.projectRoot = argv[++i] || '';
    } else if (arg === '--skill-dir') {
      parsed.skillDir = argv[++i] || '';
    } else if (arg === '--dry-run') {
      parsed.dryRun = true;
    } else if (arg === '--confirm-conflicts') {
      parsed.confirmConflicts = true;
    } else if (arg === '--json') {
      parsed.json = true;
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else {
      die(`unknown argument: ${arg}`);
    }
  }
  return parsed;
}

function buildPlan() {
  const operations = [];
  operations.push(managedFilesOp());
  operations.push(mergeSettingsHooksOp());
  operations.push(writePolicyOp());
  operations.push(writeSentinelOp());
  operations.push(touchFileOp(path.join(projectRoot, '.claude', '.agents-pending-restart'), 'pending-restart'));
  return operations;
}

function buildManagedPlan() {
  const hooks = path.join(templatesDir, 'hooks');
  const deslopHooks = path.join(skillDir, 'references', 'internal-skills', 'story-deslop', 'scripts');
  const rules = path.join(templatesDir, 'rules');
  const agents = path.join(templatesDir, 'agents');
  const references = path.join(setupDir, 'references', 'agent-references');
  const scripts = path.join(skillDir, 'scripts');
  assertDirectory(hooks, 'hooks source');
  assertDirectory(deslopHooks, 'story-deslop hook source');
  assertDirectory(rules, 'rules source');
  assertDirectory(agents, 'agents source');
  assertDirectory(references, 'agent references source');
  assertDirectory(scripts, 'runtime scripts source');
  if (!fs.existsSync(path.join(scripts, 'lib'))) die('missing runtime scripts lib directory');
  return planManagedSync({
    projectRoot: managedProjectRoot,
    sourceRoot: [
      { source: hooks, target: '.claude/hooks' },
      // ai-trace-detector.sh reads its adjacent pattern file. Keep the detector
      // and its rules together instead of leaving a stale PostToolUse command.
      { source: deslopHooks, target: '.claude/hooks' },
      { source: rules, target: '.claude/rules' },
      { source: agents, target: '.claude/agents' },
      { source: references, target: '.claude/agent-references/novel-assistant' },
      { source: scripts, target: 'scripts' },
    ],
    previousManifest: readJsonIfExists(path.join(projectRoot, '.story-runtime-managed.json')),
    bundleId: manifest.bundleId || 'unknown',
  });
}

function managedPreviewItems() {
  return [
    managedPreviewItem('hooks', path.join(templatesDir, 'hooks'), path.join(projectRoot, '.claude', 'hooks')),
    managedPreviewItem('rules', path.join(templatesDir, 'rules'), path.join(projectRoot, '.claude', 'rules')),
    managedPreviewItem('agents', path.join(templatesDir, 'agents'), path.join(projectRoot, '.claude', 'agents')),
    managedPreviewItem('agent-references', path.join(setupDir, 'references', 'agent-references'), path.join(projectRoot, '.claude', 'agent-references', 'novel-assistant')),
    managedPreviewItem('scripts', path.join(skillDir, 'scripts'), path.join(projectRoot, 'scripts')),
  ];
}

function managedPreviewItem(type, source, target) {
  return { type, source, target, count: countFiles(source) };
}

function managedFilesOp() {
  return {
    type: 'managed-files',
    target: projectRoot,
    count: managedPlan.operations.length,
    apply(safeFs) {
      return applyManagedSync(managedPlan, { confirmConflicts: args.confirmConflicts, safeFs });
    },
  };
}

function mergeSettingsHooksOp() {
  const source = path.join(templatesDir, 'settings-hooks.json');
  const target = path.join(projectRoot, '.claude', 'settings.local.json');
  const template = readRequiredJson(source, 'settings hooks template');
  return {
    type: 'settings-hooks',
    source,
    target,
    count: 1,
    apply(safeFs) {
      const existing = fs.existsSync(target) ? readRequiredJson(target, 'project settings') : {};
      const mode = fs.existsSync(target) ? fs.statSync(target).mode & 0o777 : 0o600;
      safeFs.writeFile('.claude/settings.local.json', Buffer.from(`${JSON.stringify(mergeHookSettings(existing, template), null, 2)}\n`), mode);
    },
  };
}

function mergeHookSettings(existing, template) {
  const output = { ...existing, hooks: { ...(existing.hooks || {}) } };
  for (const [event, templateGroups] of Object.entries(template.hooks || {})) {
    const groups = Array.isArray(output.hooks[event]) ? [...output.hooks[event]] : [];
    const cleanedGroups = event === 'PreToolUse' ? removeCanonicalGuardHooks(groups) : groups;
    const commands = new Set(cleanedGroups.flatMap(group => (group.hooks || []).map(hook => hook.command).filter(Boolean)));
    for (const templateGroup of templateGroups) {
      const hooks = (templateGroup.hooks || []).filter(hook => !isCanonicalGuardHook(hook) && (!hook.command || !commands.has(hook.command)));
      if (!hooks.length) continue;
      hooks.forEach(hook => { if (hook.command) commands.add(hook.command); });
      cleanedGroups.push({ ...templateGroup, hooks });
    }
    if (event === 'PreToolUse') addCanonicalGuardHook(cleanedGroups, templateGroups);
    output.hooks[event] = cleanedGroups;
  }
  return output;
}

function removeCanonicalGuardHooks(groups) {
  return groups.map(group => ({
    ...group,
    hooks: (group.hooks || []).filter(hook => !isCanonicalGuardHook(hook)),
  })).filter(group => (group.hooks || []).length > 0);
}

function isCanonicalGuardHook(hook) {
  return Boolean(hook && String(hook.command || '').includes('canonical-write-guard.js'));
}

function addCanonicalGuardHook(groups, templateGroups) {
  const templateHook = templateGroups.flatMap(group => group.hooks || []).find(isCanonicalGuardHook);
  if (!templateHook) return;
  let group = groups.find(item => item.matcher === 'Write|Edit|MultiEdit');
  if (!group) {
    group = { matcher: 'Write|Edit|MultiEdit', hooks: [] };
    groups.push(group);
  }
  const hook = { ...templateHook };
  delete hook.if;
  group.hooks = [...(group.hooks || []), hook];
}

function writePolicyOp() {
  const target = path.join(projectRoot, '追踪', 'story-system', 'write-policy.json');
  const mode = isExistingStoryProject(projectRoot) ? 'legacy' : 'strict';
  return {
    type: 'write-policy',
    target,
    mode,
    count: 1,
    apply(safeFs) {
      safeFs.writeFileIfMissing(
        '追踪/story-system/write-policy.json',
        Buffer.from(`${JSON.stringify({ schemaVersion: '1.0.0', mode }, null, 2)}\n`),
        0o644,
      );
    },
  };
}

function isExistingStoryProject(root) {
  if (fs.existsSync(path.join(root, '.story-deployed'))) return true;
  return ['正文', '大纲', '细纲', '设定', '追踪', '正文.md', '设定.md', '小节大纲.md']
    .some(relative => hasExistingStoryEvidence(path.join(root, relative)));
}

function hasExistingStoryEvidence(file) {
  if (!fs.existsSync(file)) return false;
  const stat = fs.statSync(file);
  if (stat.isFile()) return stat.size > 0;
  if (!stat.isDirectory()) return false;
  for (const entry of fs.readdirSync(file, { withFileTypes: true })) {
    if (hasExistingStoryEvidence(path.join(file, entry.name))) return true;
  }
  return false;
}

function effectiveWritePolicy(operation) {
  const existing = readJsonIfExists(operation.target);
  if (existing && ['strict', 'legacy'].includes(existing.mode)) return existing.mode;
  return operation.mode;
}

function writeSentinelOp() {
  const target = path.join(projectRoot, '.story-deployed');
  return {
    type: 'sentinel',
    target,
    count: 1,
    apply(safeFs) {
      const lines = [
        `deployed_at: ${new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')}`,
        `agents_version: ${Number(manifest.agentsVersion || 18)}`,
        `setup_skill_version: ${String(manifest.setupSkillVersion || '1.4.5')}`,
        'target_cli: claude-code',
        'resolver_strategy: global-skill-with-project-agent-references',
        'references_dir: .claude/agent-references/novel-assistant',
        `novel_assistant_bundle_id: ${manifest.bundleId || 'unknown'}`,
        `novel_assistant_bundle_name: ${manifest.bundleName || 'novel-assistant'}`,
        `novel_assistant_source_commit: ${manifest.sourceCommit || 'unknown'}`,
        `novel_assistant_source_branch: ${manifest.sourceBranch || 'unknown'}`,
        `novel_assistant_private_overlay: ${Boolean(manifest.sourceLayout && manifest.sourceLayout.includePrivate)}`,
        `novel_assistant_script_count: ${runtimeScriptCount()}`,
        'migration_status: not_requested',
        '',
      ];
      const mode = fs.existsSync(target) ? fs.statSync(target).mode & 0o777 : 0o644;
      safeFs.writeFile('.story-deployed', Buffer.from(lines.join('\n')), mode);
    },
  };
}

function runtimeScriptCount() {
  const sourceDir = path.join(skillDir, 'scripts');
  if (!fs.existsSync(sourceDir)) return SCRIPT_NAMES.length;
  return fs.readdirSync(sourceDir, { withFileTypes: true }).filter(entry => entry.isFile()).length;
}

function touchFileOp(target, type) {
  return {
    type,
    target,
    count: 1,
    apply(safeFs) {
      safeFs.writeFileIfMissing(projectRelativePath(target), Buffer.alloc(0), 0o644);
    },
  };
}

function applyPlan(plan, safeFs) {
  let managedResult = null;
  for (const item of plan) {
    const itemResult = item.apply(safeFs);
    if (item.type !== 'managed-files') continue;
    managedResult = itemResult;
    if (itemResult.status !== 'synced') break;
  }
  return managedResult;
}

function projectRelativePath(target) {
  return path.relative(projectRoot, target).split(path.sep).join('/');
}

function countFiles(dir) {
  let count = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) count += countFiles(fullPath);
    else if (entry.isFile()) count += 1;
  }
  return count;
}

function assertDirectory(dir, label) {
  let stat;
  try {
    stat = fs.statSync(dir);
  } catch (error) {
    die(`missing ${label}: ${dir}`);
  }
  if (!stat.isDirectory()) die(`${label} is not a directory: ${dir}`);
}

function resolveSkillDirectory(explicit) {
  if (explicit) return path.resolve(explicit);
  const home = process.env.HOME || '';
  const candidates = [
    process.env.NOVEL_ASSISTANT_SKILL_DIR || '',
    path.join(__dirname, '..'),
    home ? path.join(home, '.claude', 'skills', 'novel-assistant') : '',
    home ? path.join(home, '.codex', 'skills', 'novel-assistant') : '',
    home ? path.join(home, '.zcode', 'skills', 'novel-assistant') : '',
  ].filter(Boolean).map(item => path.resolve(item));
  const valid = [...new Set(candidates)].filter(item => {
    try {
      return fs.statSync(path.join(item, 'novel-assistant-manifest.json')).isFile()
        && fs.statSync(path.join(item, 'references', 'internal-skills', 'story-setup')).isDirectory();
    } catch (_) {
      return false;
    }
  });
  if (!valid.length) die('cannot locate an installed novel-assistant skill; set NOVEL_ASSISTANT_SKILL_DIR once and retry');
  valid.sort((left, right) => {
    const leftTime = fs.statSync(path.join(left, 'novel-assistant-manifest.json')).mtimeMs;
    const rightTime = fs.statSync(path.join(right, 'novel-assistant-manifest.json')).mtimeMs;
    return rightTime - leftTime || left.localeCompare(right);
  });
  return valid[0];
}

function descriptorSafeProjectRoot(root) {
  const parsed = path.parse(root);
  const segments = root.slice(parsed.root.length).split(path.sep).filter(Boolean);
  if (!segments.length) return root;
  const firstComponent = path.join(parsed.root, segments[0]);
  const stat = fs.lstatSync(firstComponent);
  if (!stat.isSymbolicLink() || path.dirname(firstComponent) !== parsed.root || stat.uid !== 0) return root;
  return path.join(fs.realpathSync(firstComponent), ...segments.slice(1));
}

function readJsonIfExists(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function readRequiredJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    die(`could not read ${label}: ${error.message}`);
  }
}

function die(message) {
  console.error(message);
  console.error(USAGE.trimEnd());
  process.exit(2);
}

function rejectRootResolution(rootResolution) {
  const result = {
    status: 'blocked_project_root',
    root_resolution: rootResolution,
  };
  if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else console.error(`project root rejected: ${rootResolution.root_kind}`);
  process.exit(2);
}
