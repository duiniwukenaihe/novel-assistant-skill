'use strict';

const fs = require('fs');
const path = require('path');
const { normalizeUsage } = require('./behavior-eval-contract');
const { buildStageContextPacket } = require('./workflow-stage-context-packet');
const { buildLongStageContextPacket } = require('./long-stage-context-packet');

const ADAPTERS = ['claude-code', 'codex', 'zcode', 'fake'];
const EVALUATION_ADAPTERS = Object.freeze({
  claude: 'claude-code',
  codex: 'codex',
  zcode: 'zcode',
});
const DEFAULT_ZCODE_PATHS = [
  '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs',
  '/usr/local/bin/zcode',
  '/opt/homebrew/bin/zcode',
];
const USAGE_HOSTS = Object.freeze({
  'claude-code': 'claude',
  codex: 'codex',
  zcode: 'zcode',
  fake: 'codex',
});

function detectAdapters(options = {}) {
  const overrides = options.executableOverrides || {};
  const adapters = {};
  for (const adapter of ['claude-code', 'codex', 'zcode']) {
    const executable = resolveExecutable(adapter, overrides);
    adapters[adapter] = {
      available: Boolean(executable),
      executable: executable || '',
    };
  }
  return {
    selected: '',
    adapters,
    recommendation: 'Choose --adapter claude-code, codex, or zcode explicitly before a paid run.',
  };
}

function buildAdapterInvocation(adapter, request = {}) {
  if (adapter === 'auto') throw new Error('Choose an explicit adapter before execution.');
  if (!ADAPTERS.includes(adapter)) throw new Error(`unsupported adapter: ${adapter}`);

  const projectRoot = path.resolve(String(request.projectRoot || ''));
  if (!request.projectRoot || !fs.existsSync(projectRoot)) throw new Error('projectRoot must exist');
  const prompt = String(request.prompt || '').trim();
  if (!prompt) throw new Error('prompt is required');

  const overrides = request.executableOverrides || {};
  const promptFile = createPromptFile(projectRoot, prompt, request.runId);
  const env = {
    ...minimalEnvironment(),
    NOVEL_ASSISTANT_RUN_ID: String(request.runId || ''),
    NOVEL_ASSISTANT_RUNNER_PACKET: String(request.runnerPacket || ''),
    NOVEL_ASSISTANT_RESULT_PACKET: String(request.expectedResultPacket || ''),
    NOVEL_ASSISTANT_PROJECT_ROOT: projectRoot,
    NOVEL_ASSISTANT_PROMPT_FILE: promptFile,
    NOVEL_ASSISTANT_EVALUATION_ATTEMPT: String(request.evaluationAttempt || 0),
    NOVEL_ASSISTANT_EVALUATION_HOST: String(request.evaluationHost || ''),
  };
  // Hosts do not reliably expose environment variables to the model. Give the
  // model one exact, project-local path instead of making it search for a
  // prompt file; the detailed prompt itself stays out of argv.
  const skillCommand = String(request.skillCommand || '').trim();
  const relayPrompt = [
    skillCommand,
    `Read and follow the exact instruction file at ${promptFile}. Do not search for other prompt files.`,
  ].filter(Boolean).join('\n');

  if (adapter === 'claude-code') {
    const command = requiredExecutable(adapter, overrides);
    const args = [
      '-p',
      relayPrompt,
      '--output-format',
      'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--permission-mode',
      String(request.permissionMode || 'acceptEdits'),
      '--add-dir',
      projectRoot,
      '--prompt-suggestions',
      'false',
    ];
    if (request.maxBudgetUsd !== undefined && request.maxBudgetUsd !== null && request.maxBudgetUsd !== '') {
      const budget = Number(request.maxBudgetUsd);
      if (!Number.isFinite(budget) || budget <= 0) throw new Error('maxBudgetUsd must be positive');
      args.push('--max-budget-usd', String(budget));
    }
    return invocation(command, args, projectRoot, env);
  }

  if (adapter === 'codex') {
    const command = requiredExecutable(adapter, overrides);
    const args = [
      'exec',
      '--json',
      '--color',
      'never',
      '--skip-git-repo-check',
      '-C',
      projectRoot,
      '--sandbox',
      String(request.sandbox || 'workspace-write'),
      relayPrompt,
    ];
    if (request.ignoreUserConfig === true) args.splice(args.indexOf('--skip-git-repo-check'), 0, '--ignore-user-config');
    return invocation(command, args, projectRoot, env);
  }

  if (adapter === 'zcode') {
    const executable = requiredExecutable(adapter, overrides);
    const args = [
      '--cwd',
      projectRoot,
      '--mode',
      String(request.permissionMode || 'edit'),
      '--json',
      '--prompt',
      relayPrompt,
    ];
    if (/\.(?:c?js|mjs)$/i.test(executable)) {
      return invocation(process.execPath, [executable, ...args], projectRoot, env);
    }
    return invocation(executable, args, projectRoot, env);
  }

  const fakeExecutable = String(request.fakeExecutable || '');
  if (!fakeExecutable) throw new Error('fakeExecutable is required for fake adapter');
  const fakeArgs = Array.isArray(request.fakeArgs) ? request.fakeArgs.map(String) : [];
  if (/\.(?:c?js|mjs)$/i.test(fakeExecutable)) {
    return invocation(process.execPath, [fakeExecutable, ...fakeArgs], projectRoot, env);
  }
  return invocation(fakeExecutable, fakeArgs, projectRoot, env);
}

function resolveEvaluationAdapter(host) {
  const adapter = EVALUATION_ADAPTERS[String(host || '')];
  if (!adapter) throw new Error(`unsupported evaluation host: ${host}`);
  return adapter;
}

function invocation(command, args, cwd, env) {
  return {
    command,
    args,
    cwd,
    env,
    shell: false,
    stdio: ['ignore', 'pipe', 'pipe'],
  };
}

function minimalEnvironment() {
  const env = {};
  for (const key of ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'TERM']) {
    if (process.env[key]) env[key] = process.env[key];
  }
  return env;
}

function createPromptFile(projectRoot, prompt, runId) {
  const directory = path.join(projectRoot, '.novel-assistant', 'evaluation-prompts');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
  const safeRunId = String(runId || `prompt-${process.pid}`).replace(/[^A-Za-z0-9._-]/g, '_');
  const file = path.join(directory, `${safeRunId}.txt`);
  fs.writeFileSync(file, `${prompt}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.chmodSync(file, 0o600);
  return file;
}

function requiredExecutable(adapter, overrides) {
  if (Object.prototype.hasOwnProperty.call(overrides, adapter) && String(overrides[adapter] || '')) {
    return path.resolve(String(overrides[adapter]));
  }
  const executable = resolveExecutable(adapter, overrides);
  if (!executable) throw new Error(`${adapter} executable not found`);
  return executable;
}

function resolveExecutable(adapter, overrides = {}) {
  if (Object.prototype.hasOwnProperty.call(overrides, adapter)) {
    return isUsableFile(overrides[adapter]) ? path.resolve(overrides[adapter]) : '';
  }
  if (adapter === 'claude-code') return findOnPath('claude');
  if (adapter === 'codex') return findOnPath('codex');
  if (adapter === 'zcode') {
    const onPath = findOnPath('zcode');
    if (onPath) return onPath;
    return DEFAULT_ZCODE_PATHS.find(isUsableFile) || '';
  }
  return '';
}

function findOnPath(name) {
  const pathEntries = String(process.env.PATH || '').split(path.delimiter).filter(Boolean);
  for (const entry of pathEntries) {
    const candidate = path.join(entry, name);
    if (isUsableFile(candidate)) return candidate;
  }
  return '';
}

function isUsableFile(file) {
  if (!file) return false;
  try {
    const stat = fs.statSync(file);
    return stat.isFile() || stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function normalizeHostUsage(adapter, events, durationMs = 0, options = {}) {
  const host = USAGE_HOSTS[String(adapter || '')];
  const proxyAvailable = Number.isFinite(Number(options.outputChars)) && Number(options.outputChars) > 0;
  if (!host) return unavailableOrEstimated(durationMs, ['unsupported_adapter'], proxyAvailable);

  const usage = normalizeUsage(host, events);
  const observedDuration = nonNegativeNumber(durationMs);
  if (!usage.complete || usage.source !== 'host') {
    const missingFields = (usage.invalidFields || []).length
      ? usage.invalidFields
      : ['input_tokens', 'output_tokens'];
    return unavailableOrEstimated(Math.max(observedDuration, nonNegativeNumber(usage.durationMs)), missingFields, proxyAvailable);
  }

  return {
    token_source: 'host',
    available: true,
    input_tokens: nonNegativeNumber(usage.inputTokens),
    output_tokens: nonNegativeNumber(usage.outputTokens),
    cache_read_tokens: nonNegativeNumber(usage.cacheReadTokens),
    cache_write_tokens: nonNegativeNumber(usage.cacheWriteTokens),
    duration_ms: Math.max(observedDuration, nonNegativeNumber(usage.durationMs)),
    missing_fields: [],
    findings: [],
    snapshot_strategy: usage.snapshotStrategy || 'single_terminal',
    actual_usd: Number.isFinite(usage.actualUsd) ? usage.actualUsd : null,
  };
}

function unavailableOrEstimated(durationMs, missingFields, proxyAvailable) {
  const invalid = Array.isArray(missingFields) && missingFields.some(field => /cache|duration/i.test(field));
  return {
    token_source: proxyAvailable ? 'estimated' : 'unavailable',
    available: false,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    duration_ms: nonNegativeNumber(durationMs),
    missing_fields: missingFields,
    findings: invalid ? [{ code: 'invalid_host_usage_metric', severity: 'warning', fields: missingFields }] : [],
    snapshot_strategy: 'unavailable',
    actual_usd: null,
  };
}

function nonNegativeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

// Turn either short- or long-form stage packets into one compact host hint.
// This cannot interrupt hidden model thinking; managed_runner is required for
// enforceable streaming health control.
function composeStageContextGuidance(stageContextPacket) {
  const packet = stageContextPacket || {};
  if (packet.status !== 'assembled' || !packet.packet_md) {
    // No usable packet: inject nothing. Do not fabricate an allowlist.
    return '';
  }
  const sourceIds = Array.isArray(packet.source_files)
    ? packet.source_files.map((entry) => String((entry && (entry.id || entry.path)) || '')).filter(Boolean)
    : [];
  const lines = [
    '当前写作单元已注入唯一最小上下文包，请先读取它，并只使用包内资产完成当前阶段。',
    `最小上下文包：${packet.packet_md}`,
  ];
  if (sourceIds.length) {
    lines.push(`包内资产（仅限）：${sourceIds.join('、')}`);
  }
  if (Number(packet.estimated_tokens) > 0) {
    lines.push(`上下文预算约 ${packet.estimated_tokens} tokens；不要自由搜索其他文件，不要读取全量 journal/result-packets/scripts。`);
  } else {
    lines.push('不要自由搜索其他文件，不要读取全量 journal/result-packets/scripts。');
  }
  lines.push('如果会话上下文已显著膨胀，建议改由托管运行（managed_runner）接管本节；协作模式无法中断已生成的隐藏思考，只能建议。');
  return lines.join('\n');
}

module.exports = {
  ADAPTERS,
  EVALUATION_ADAPTERS,
  buildAdapterInvocation,
  buildLongStageContextPacket,
  buildStageContextPacket,
  composeStageContextGuidance,
  detectAdapters,
  minimalEnvironment,
  normalizeHostUsage,
  resolveEvaluationAdapter,
  resolveExecutable,
};
