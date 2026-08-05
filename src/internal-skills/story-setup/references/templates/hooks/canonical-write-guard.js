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
  if (targetOutsideProject(target, projectRoot)) {
    emit({ status: 'not_applicable', reason: 'target_outside_story_project' });
    return 0;
  }
  const expectedResultWrite = validateExpectedResultPacketWrite(target, payload, projectRoot);
  if (expectedResultWrite) {
    if (expectedResultWrite.allowed) {
      emit({ status: 'allowed_expected_result_packet', target: expectedResultWrite.target });
      return 0;
    }
    return deny(expectedResultWrite.code, expectedResultWrite.message, { target: expectedResultWrite.target });
  }
  const workflowStateTarget = directWorkflowStateTarget(target, projectRoot);
  if (workflowStateTarget) {
    return deny('blocked_direct_workflow_state_edit', '禁止使用 Write/Edit 直接修补 workflow 权威状态。请调用 workflow-state-machine.js 或 workflow-stage-controller.js 的受控命令。', { target: workflowStateTarget });
  }
  const adHocWorkflowHelper = unmanagedWorkflowHelper(target, projectRoot);
  if (adHocWorkflowHelper) {
    return deny('blocked_ad_hoc_workflow_helper', '当前素材学习阶段已有受控执行器，禁止在项目 scripts/ 下创建临时辅助脚本。请逐字执行状态机返回的 context_read_command 和 execution_command。', { target: adHocWorkflowHelper });
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

function validateExpectedResultPacketWrite(target, payload, projectRoot) {
  const relative = relativeProjectPath(target, projectRoot);
  if (!/^\u8ffd\u8e2a\/workflow\/tasks\/[^/]+\/result-packets\/[^/]+\.result\.json$/u.test(relative)) return null;
  const blocked = (code, message) => ({ allowed: false, code, message, target: relative });
  if (findString(payload, ['tool_name', 'toolName']) !== 'Write') {
    return blocked('blocked_direct_workflow_state_edit', '只允许 Write 创建当前运行阶段的唯一预期回执。');
  }
  const pointer = readJson(path.join(projectRoot, '追踪', 'workflow', 'current-task.json'));
  const taskFile = pointer && pointer.task_dir
    ? path.join(projectRoot, pointer.task_dir, 'task.json')
    : '';
  const task = readJson(taskFile);
  const execution = task && task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : {};
  if (!task || String(execution.status || '') !== 'running') {
    return blocked('blocked_direct_workflow_state_edit', '当前没有正在运行且等待回执的 workflow 阶段。');
  }
  const expected = String(execution.expected_result_packet || '').replace(/\\/g, '/');
  if (!expected || expected !== relative) {
    return blocked('blocked_direct_workflow_state_edit', '只能写入当前阶段 expected_result_packet 指向的唯一回执。');
  }
  const absolute = path.resolve(projectRoot, relative);
  if (require('fs').existsSync(absolute)) {
    return blocked('blocked_result_packet_already_exists', '当前阶段回执已存在；禁止用模型工具覆盖可信结果。');
  }
  const content = findString(payload, ['content']);
  let packet;
  try {
    packet = JSON.parse(content);
  } catch (_) {
    return blocked('blocked_result_packet_invalid', '当前阶段回执必须是合法 JSON。');
  }
  if (String(packet.workflow_id || '') !== String(task.workflow_id || '')
      || String(packet.stage_id || '') !== String(execution.stage_id || task.current_stage || '')
      || String(packet.result_packet_path || '').replace(/\\/g, '/') !== expected
      || !['completed', 'blocked'].includes(String(packet.step_status || ''))) {
    return blocked('blocked_result_packet_identity_mismatch', '回执的 workflow、stage、status 或声明路径与当前运行阶段不一致。');
  }
  const expectedOwner = String(execution.owner_module || '');
  if (expectedOwner && String(packet.owner_module || '') !== expectedOwner) {
    return blocked('blocked_result_packet_identity_mismatch', '回执 owner_module 与当前运行阶段不一致。');
  }
  return { allowed: true, target: relative };
}

function readJson(file) {
  try {
    return file && require('fs').existsSync(file)
      ? JSON.parse(require('fs').readFileSync(file, 'utf8'))
      : null;
  } catch (_) {
    return null;
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

function unmanagedWorkflowHelper(target, projectRoot) {
  const relativeTarget = relativeProjectPath(target, projectRoot);
  if (!/^scripts\/(?:_|tmp|debug|inspect|list|resolve|generate)[A-Za-z0-9_.-]*\.(?:py|c?js|mjs)$/iu.test(relativeTarget)) return '';
  const pointer = path.join(projectRoot, '追踪', 'workflow', 'current-task.json');
  try {
    const current = JSON.parse(require('fs').readFileSync(pointer, 'utf8'));
    const taskFile = current.task_dir ? path.join(projectRoot, current.task_dir, 'task.json') : pointer;
    const task = JSON.parse(require('fs').readFileSync(taskFile, 'utf8'));
    return String(task.current_stage || '') === 'material_learning' ? relativeTarget : '';
  } catch (_) {
    return '';
  }
}

function relativeProjectPath(target, projectRoot) {
  const value = String(target || '').replace(/\\/g, path.sep);
  const absolute = path.isAbsolute(value) ? path.resolve(value) : path.resolve(projectRoot, value);
  const relative = path.relative(projectRoot, absolute);
  if (!relative || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return '';
  return relative.split(path.sep).join('/');
}

function targetOutsideProject(target, projectRoot) {
  const value = String(target || '').replace(/\\/g, path.sep);
  const absolute = path.isAbsolute(value) ? path.resolve(value) : path.resolve(projectRoot, value);
  const relative = path.relative(projectRoot, absolute);
  return Boolean(relative && (relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)));
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
