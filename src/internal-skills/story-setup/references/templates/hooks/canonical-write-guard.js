#!/usr/bin/env node
'use strict';

const path = require('path');

function main() {
  const payload = readHookPayload();
  const target = findString(payload, ['file_path', 'filePath', 'path']);
  if (!target) {
    return warning('canonical_write_target_missing', 'hook input did not include a file path');
  }

  const projectRoot = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  const workflowStateTarget = directWorkflowStateTarget(target, projectRoot);
  if (workflowStateTarget) {
    return deny('blocked_direct_workflow_state_edit', '禁止使用 Write/Edit 直接修补 workflow 权威状态。请调用 workflow-state-machine.js 或 workflow-stage-controller.js 的受控命令。', { target: workflowStateTarget });
  }
  const mutator = unmanagedStoryMutator(target, payload, projectRoot);
  if (mutator) {
    return deny('blocked_unmanaged_story_mutator', '禁止创建会直接改写正式小说资产的临时脚本。请先生成候选稿并通过质量门，再使用 chapter-commit.js prepare/accept 进入正式资产。', {
      target: mutator.target,
      canonical_references: mutator.canonicalReferences,
    });
  }
  let policy;
  try {
    policy = require(path.join(projectRoot, 'scripts', 'lib', 'canonical-write-policy.js'));
  } catch (error) {
    return runtimeUnavailable(projectRoot, error);
  }

  try {
    const result = policy.assertCanonicalWriteAllowed(projectRoot, [target], {
      transactionId: findString(payload, ['transaction_id', 'transactionId', 'transaction']),
    });
    emit(result);
    return 0;
  } catch (error) {
    return deny(error.code || 'blocked_canonical_write_guard_error', error.message, { targets: error.targets || [] });
  }
}

function directWorkflowStateTarget(target, projectRoot) {
  const relative = relativeProjectPath(target, projectRoot);
  if (!relative) return '';
  if (relative === '追踪/workflow/current-task.json') return relative;
  if (relative === '追踪/workflow/task-index.json') return relative;
  if (/^追踪\/workflow\/tasks\/[^/]+\/task\.json$/u.test(relative)) return relative;
  if (/^追踪\/workflow\/task-families\/[^/]+\.json$/u.test(relative)) return relative;
  if (/^追踪\/workflow\/tasks\/[^/]+\/result-packets\/[^/]+\.result\.json$/u.test(relative)) return relative;
  if (/^追踪\/workflow\/tasks\/[^/]+\/artifacts\/section-\d+-acceptance\.json$/u.test(relative)) return relative;
  if (/^追踪\/private-short-extension\/(?:briefs\/section-\d+\.json|section-\d+-anchor\.json|project-state\.json|section-title-lock\.json)$/u.test(relative)) return relative;
  return '';
}

function runtimeUnavailable(projectRoot, error) {
  const message = `could not load canonical write policy: ${error.message}`;
  if (declaredPolicyRequiresStrictGuard(projectRoot)) {
    return deny('blocked_canonical_write_guard_runtime_unavailable', message);
  }
  return warning('canonical_write_guard_runtime_missing', message);
}

function declaredPolicyRequiresStrictGuard(projectRoot) {
  const file = path.join(projectRoot, '追踪', 'story-system', 'write-policy.json');
  try {
    const policy = JSON.parse(require('fs').readFileSync(file, 'utf8'));
    return policy.mode !== 'legacy';
  } catch (_) {
    return require('fs').existsSync(file);
  }
}

function readHookPayload() {
  const raw = process.env.CLAUDE_TOOL_INPUT || readStdin();
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function readStdin() {
  try {
    return require('fs').readFileSync(0, 'utf8');
  } catch (_) {
    return '';
  }
}

function findString(value, names) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findString(item, names);
      if (found) return found;
    }
    return '';
  }
  if (!value || typeof value !== 'object') return '';
  for (const name of names) {
    if (typeof value[name] === 'string' && value[name].trim()) return value[name].trim();
  }
  for (const child of Object.values(value)) {
    const found = findString(child, names);
    if (found) return found;
  }
  return '';
}

function unmanagedStoryMutator(target, payload, projectRoot) {
  const relativeTarget = relativeProjectPath(target, projectRoot);
  if (!/^scripts\/(?:apply|fix|repair|rewrite|patch)[A-Za-z0-9_.-]*\.(?:c?js|mjs)$/i.test(relativeTarget)) return null;
  const content = findString(payload, ['content', 'new_string', 'newString']);
  if (!content || !/(?:writeFile|appendFile|copyFile|rename|rmSync|unlinkSync)\w*\s*\(/.test(content)) return null;
  const canonicalReferences = [...new Set((content.match(/(?:正文(?:\/|\.md)|大纲\/|细纲\/|设定\.md|追踪\/(?:伏笔|时间线|角色状态|上下文)\.md)/g) || []))];
  if (!canonicalReferences.length) return null;
  return { target: relativeTarget, canonicalReferences };
}

function relativeProjectPath(target, projectRoot) {
  const value = String(target || '').replace(/\\/g, path.sep);
  const absolute = path.isAbsolute(value) ? path.resolve(value) : path.resolve(projectRoot, value);
  const relative = path.relative(projectRoot, absolute);
  if (!relative || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return '';
  return relative.split(path.sep).join('/');
}

function warning(code, message) {
  emit({ status: 'warning', warning: code, message });
  return 0;
}

function deny(code, message, details = {}) {
  emit({
    status: code,
    message,
    ...details,
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: `${message} [${code}]`,
    },
  });
  return 0;
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

process.exitCode = main();
