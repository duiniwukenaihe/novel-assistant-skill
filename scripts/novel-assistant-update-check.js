#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  computeManifestSourceInputDigest,
  computeManifestSourceTreeId,
  findRepositoryRoot,
  sourceCommit,
} = require('./lib/bundle-version');
const { resolveProjectRoot } = require('./lib/project-root-resolver');
const { atomicWriteJson } = require('./lib/workflow-state-store');

const args = process.argv.slice(2);
const userIntent = optionValue(args, '--user-intent');
const writeChoice = args.includes('--write');
const optionValueIndexes = new Set();
for (const name of ['--user-intent']) {
  const index = args.indexOf(name);
  if (index >= 0) {
    optionValueIndexes.add(index);
    optionValueIndexes.add(index + 1);
  }
}
const positional = args.filter((arg, index) => !arg.startsWith('--') && !optionValueIndexes.has(index));
const projectRoot = positional[0];
const manifestPath = positional[1] || discoverManifestPath();
const jsonOutput = args.includes('--json');

if (!projectRoot) {
  fail('usage: novel-assistant-update-check.js <project-root> [manifest.json] [--json]');
}

const rootResolution = resolveProjectRoot({ cwd: process.cwd(), explicitBookRoot: projectRoot });
const manifestAbs = path.resolve(manifestPath);
if (rootResolution.status !== 'resolved' || rootResolution.root_kind !== 'book') {
  writeResult({
    status: 'root_resolution_rejected',
    shouldPrompt: false,
    shouldRunSetup: false,
    projectRoot: '',
    root_resolution: rootResolution,
    message: 'novel-assistant project root must resolve to one book directory',
    recommendedPrompt: '',
  });
  process.exit(2);
}

const projectAbs = rootResolution.book_root;
const manifest = readJson(manifestAbs);
const sentinelPath = path.join(projectAbs, '.story-deployed');
const sentinel = fs.existsSync(sentinelPath) ? readSentinel(sentinelPath) : null;
const repositoryRoot = findRepositoryRoot(manifestAbs, manifest.bundleName || 'novel-assistant');
const computedSourceTreeId = repositoryRoot && manifest.sourceTreeId
  ? computeManifestSourceTreeId(repositoryRoot, manifest.bundleName || 'novel-assistant', manifest.sourceLayout)
  : null;
const computedSourceInputDigest = repositoryRoot && manifest.sourceInputDigest
  ? computeManifestSourceInputDigest(repositoryRoot, manifest.bundleName || 'novel-assistant', manifest.sourceLayout)
  : null;
const currentCommit = repositoryRoot ? sourceCommit(repositoryRoot) : '';
const checked = {
  ...buildResult(projectAbs, manifest, sentinel, { computedSourceTreeId, computedSourceInputDigest, currentCommit }),
  root_resolution: rootResolution,
};
const result = resolveUpdateChoice({
  projectRoot: projectAbs,
  checked,
  userIntent,
  writeChoice,
});

writeResult(result);

function optionValue(argv, name) {
  const index = argv.indexOf(name);
  return index >= 0 ? String(argv[index + 1] || '') : '';
}

function discoverManifestPath() {
  const candidates = [
    path.resolve(__dirname, '..', 'novel-assistant-manifest.json'),
    path.resolve(__dirname, '..', 'skills', 'novel-assistant', 'novel-assistant-manifest.json'),
  ];
  return candidates.find(candidate => fs.existsSync(candidate)) || candidates[0];
}

function writeResult(result) {
  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${result.message}\n`);
  }
}

function resolveUpdateChoice({ projectRoot: root, checked: current, userIntent: intent, writeChoice: persist }) {
  const stateFile = path.join(root, '追踪', 'workflow', 'update-environment-choice.json');
  const prior = readOptionalJson(stateFile);
  const pending = prior && prior.type === 'update_environment' && prior.status === 'pending' ? prior : null;

  if (current.status === 'current') {
    if (!pending) return current;
    const resolved = {
      ...pending,
      status: 'resolved',
      selection: { action_id: 'environment_now_current', label: '写作协作环境已是当前版本', number: 1 },
      resolved_at: new Date().toISOString(),
    };
    if (persist) atomicWriteJson(stateFile, resolved);
    return {
      ...current,
      status: 'current_after_update',
      original_intent: String(pending.original_intent || ''),
      resume_original_intent: true,
      entry_guard_command: buildEntryGuardCommand(pending.original_intent),
      pending_action: resolved,
    };
  }

  if (!current.shouldPrompt) return current;
  const activePending = pending && updateChoiceMatchesCheck(pending, current) ? pending : null;
  const selection = activePending ? parseUpdateChoice(intent) : null;
  if (activePending && selection) {
    const resolved = {
      ...activePending,
      status: 'resolved',
      selection,
      resolved_at: new Date().toISOString(),
    };
    if (persist) atomicWriteJson(stateFile, resolved);
    if (selection.action_id === 'continue_without_update') {
      return {
        ...current,
        status: 'update_declined',
        shouldPrompt: false,
        recommendedPrompt: '',
        original_intent: String(activePending.original_intent || ''),
        resume_original_intent: true,
        selection,
        pending_action: resolved,
        entry_guard_command: buildEntryGuardCommand(activePending.original_intent),
      };
    }
    return {
      ...current,
      status: 'update_confirmed',
      shouldPrompt: false,
      recommendedPrompt: '',
      original_intent: String(activePending.original_intent || ''),
      resume_original_intent: true,
      selection,
      pending_action: resolved,
      execution_command: `node ${shellQuote(path.join(__dirname, 'novel-assistant-sync-runtime.js'))} --project-root . --json`,
    };
  }

  const originalIntent = String((pending || {}).original_intent || intent || '');
  const action = buildPendingUpdateAction(current, originalIntent);
  if (persist) atomicWriteJson(stateFile, action);
  return {
    ...current,
    selection_contract: 'resolve_update_environment',
    pending_action: action,
  };
}

function updateChoiceMatchesCheck(pending, current) {
  return String(pending.current_bundle_id || '') === String(current.currentBundleId || '')
    && String(pending.deployed_bundle_id || '') === String(current.deployedBundleId || '');
}

function buildPendingUpdateAction(result, originalIntent) {
  const stable = [
    String(result.currentBundleId || ''),
    String(result.deployedBundleId || ''),
    String(originalIntent || ''),
  ].join('\n');
  return {
    schemaVersion: '1.0.0',
    id: `update-environment-${crypto.createHash('sha256').update(stable).digest('hex').slice(0, 16)}`,
    type: 'update_environment',
    status: 'pending',
    original_intent: String(originalIntent || ''),
    current_bundle_id: String(result.currentBundleId || ''),
    deployed_bundle_id: String(result.deployedBundleId || ''),
    options: [
      { action_id: 'update_environment_now', label: '现在更新写作协作环境', number: 1 },
      { action_id: 'continue_without_update', label: '暂不更新，继续原意图', number: 2 },
    ],
    expected_reply_set: ['1', '2', '确认', '是', 'yes', 'y', '不', '否', 'no', 'n', 'later'],
    created_at: new Date().toISOString(),
  };
}

function parseUpdateChoice(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (['1', '确认', '是', 'yes', 'y'].includes(normalized)) {
    return { action_id: 'update_environment_now', label: '现在更新写作协作环境', number: 1 };
  }
  if (['2', '不', '否', 'no', 'n', 'later'].includes(normalized)) {
    return { action_id: 'continue_without_update', label: '暂不更新，继续原意图', number: 2 };
  }
  return null;
}

function buildEntryGuardCommand(originalIntent) {
  return `node ${shellQuote(path.join(__dirname, 'workflow-entry-guard.js'))} --project-root . --user-intent ${shellQuote(String(originalIntent || ''))} --write --compact --json`;
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'"'"'`)}'`;
}

function readOptionalJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function buildResult(root, current, deployed, version = {}) {
  const sourceTreeId = current.sourceTreeId ? String(current.sourceTreeId) : null;
  const computedSourceTreeId = version.computedSourceTreeId ? String(version.computedSourceTreeId) : null;
  const sourceTreeCurrent = sourceTreeId && computedSourceTreeId ? sourceTreeId === computedSourceTreeId : null;
  const sourceInputDigest = current.sourceInputDigest ? String(current.sourceInputDigest) : null;
  const computedSourceInputDigest = version.computedSourceInputDigest ? String(version.computedSourceInputDigest) : null;
  const sourceInputCurrent = sourceInputDigest && computedSourceInputDigest
    ? sourceInputDigest === computedSourceInputDigest
    : null;
  const sourceCommitLag = Boolean(version.currentCommit && current.sourceCommit && current.sourceCommit !== version.currentCommit);
  const versionAudit = {
    sourceTreeId,
    computedSourceTreeId,
    sourceTreeCurrent,
    sourceInputDigest,
    computedSourceInputDigest,
    sourceInputCurrent,
    sourceLayout: current.sourceLayout || null,
    sourceState: String(current.sourceState || ''),
    sourceCommit: String(current.sourceCommit || ''),
    currentCommit: String(version.currentCommit || ''),
    sourceCommitLag,
  };
  if (!deployed) {
    return {
      status: 'not_deployed',
      shouldPrompt: true,
      shouldRunSetup: false,
      projectRoot: root,
      currentBundleId: current.bundleId || '',
      deployedBundleId: '',
      ...versionAudit,
      message: 'novel-assistant writing collaboration environment is not deployed',
      recommendedPrompt: renderPrompt(current, deployed),
    };
  }

  const currentBundleId = String(current.bundleId || '');
  const deployedBundleId = String(deployed.novel_assistant_bundle_id || '');
  const agentsVersion = Number(deployed.agents_version || 0);
  const currentAgentsVersion = Number(current.agentsVersion || 0);
  const setupSkillVersion = String(deployed.setup_skill_version || '');
  const currentSetupSkillVersion = String(current.setupSkillVersion || '');
  const contentCurrent = Boolean(currentBundleId && deployedBundleId && currentBundleId === deployedBundleId)
    && sourceTreeCurrent !== false
    && sourceInputCurrent !== false;
  const runtimeCurrent =
    (!currentAgentsVersion || !agentsVersion || agentsVersion >= currentAgentsVersion)
    && (!currentSetupSkillVersion || !setupSkillVersion || setupSkillVersion === currentSetupSkillVersion);
  const stale =
    !contentCurrent ||
    !runtimeCurrent ||
    !deployedBundleId;

  if (!stale) {
    return {
      status: 'current',
      shouldPrompt: false,
      shouldRunSetup: false,
      projectRoot: root,
      currentBundleId,
      deployedBundleId,
      contentCurrent,
      ...versionAudit,
      message: 'novel-assistant writing collaboration environment is current',
      recommendedPrompt: '',
    };
  }

  return {
    status: 'update_available',
    shouldPrompt: true,
    shouldRunSetup: false,
    projectRoot: root,
    currentBundleId,
    deployedBundleId,
    contentCurrent,
    ...versionAudit,
    currentAgentsVersion,
    deployedAgentsVersion: agentsVersion || null,
    currentSetupSkillVersion,
    deployedSetupSkillVersion: setupSkillVersion,
    message: 'novel-assistant writing collaboration environment update available',
    recommendedPrompt: renderPrompt(current, deployed),
  };
}

function renderPrompt(current, deployed) {
  const currentBundleId = current?.bundleId || 'unknown';
  const deployedBundleId = deployed?.novel_assistant_bundle_id || '未部署';
  const currentCommit = current?.sourceCommit || 'unknown';
  const deployedCommit = deployed?.novel_assistant_source_commit || '未记录';
  return [
    '检测到 novel-assistant 写作协作环境需要更新：',
    '',
    `当前安装版本：${currentBundleId} (${currentCommit})`,
    `本项目已部署版本：${deployedBundleId} (${deployedCommit})`,
    '',
    '建议更新写作协作环境，以同步 hooks / agents / rules / scripts / references。',
    '这不会修改正文、大纲、细纲等创作内容；如发现结构迁移，会另行请求确认。',
    '请先选择是否更新；暂不更新后，我再继续处理你的原始写作任务。',
    '',
    '是否现在更新写作协作环境？',
    '',
    '1. 现在更新写作协作环境（推荐）',
    '2. 暂不更新，继续原意图（可能缺少最新 hooks / agents / rules）',
    '',
    '回复 1/2；确认/是/yes/y 等同于 1，不/否/no/n/later 等同于 2。',
    '也可以直接输入写作/审阅/拆文等新指令。',
  ].join('\n');
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`cannot read manifest: ${file}: ${error.message}`);
  }
}

function readSentinel(file) {
  const rows = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_.-]+):\s*(.*)$/);
    if (match) rows[match[1]] = match[2].trim();
  }
  return rows;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
