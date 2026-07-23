#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const SAFE_SCRIPTS = new Set([
  'review-batch-evidence-scan.js',
  'review-evidence-map.js',
  'safe-text-search.js',
  'chapter-volume-count.js',
  'chapter-text-stats.js',
  'story-progress-status.js',
  'story-domain-profile.js',
  'workflow-state-validate.js',
  'chapter-metadata-reconcile.js',
  'workflow-entry-guard.js',
  'workflow-task-inbox.js',
  'workflow-state-machine.js',
  'workflow-stage-controller.js',
  'short-section-machine-gate.js',
  'short-section-draft-finalize.js',
  'short-section-quality-gate.js',
  'short-section-brief-finalize.js',
  'short-section-repair-finalize.js',
  'short-section-title-lock.js',
  'short-section-accept-finalize.js',
  'short-story-assembly-finalize.js',
  'short-story-review-finalize.js',
  'short-story-deslop-finalize.js',
  'short-story-final-check.js',
  'short-planning-stage-finalize.js',
  'long-chapter-machine-gate.js',
  'long-chapter-quality-gate.js',
  'novel-assistant-update-check.js',
  'novel-assistant-sync-runtime.js',
]);

function main() {
  const payload = readPayload();
  const command = findString(payload, ['command']);
  if (!command) return 0;

  const workflowMutation = detectWorkflowMutation(command);
  if (workflowMutation) return deny('禁止直接复制或改写 workflow 状态文件。请使用 scripts/workflow-state-machine.js 的对应动作提交状态。');

  if (isGeneratedStoryMutator(command)) {
    return deny('不得运行临时修复脚本直接改写正文或设定。请走候选稿 → 质量门 → chapter-commit.js prepare/accept → 复检的受控链路。');
  }

  if (isKnownSafeManagedInvocation(command)) {
    return allow('受管脚本及其有界输出截取属于已验证命令，直接放行。');
  }

  if (isLegacyManagedWorkingDirectoryInvocation(command)) {
    return allow('兼容旧宿主生成的 cd + 单个受管脚本调用；仅放行这一条白名单命令，不放宽其他复合 Bash。');
  }

  if (isGlobalSkillBundleProbe(command)) {
    return deny('novel-assistant 已由宿主加载。禁止枚举全局 skill 安装目录；请直接运行当前项目 scripts/ 下的 update-check 或 workflow-entry-guard 确定性入口。');
  }

  const shortStageMismatch = shortStageCommandMismatch(command);
  if (shortStageMismatch) {
    return allow(`短篇受管脚本与当前阶段不一致；允许脚本返回结构化恢复状态，不把业务分支显示成工具错误。${shortStageMismatch}`);
  }

  if (isBoundedReadOnlyDiagnostic(command)) {
    return allow('当前命令是安全、只读且有界的项目诊断；自动放行，后续仍应回到状态机 execution_command。');
  }

  const unsafe = detectUnsafe(command);
  if (unsafe) return deny(replacementReason(command, unsafe));

  if (isKnownSafeCommand(command)) return allow('novel-assistant 已验证的确定性只读脚本，自动放行以避免重复授权。');
  return 0;
}

function isBoundedReadOnlyDiagnostic(command) {
  const value = String(command || '').trim();
  if (!value || /\b(?:rm|mv|cp|touch|mkdir|chmod|chown|kill|pkill|git\s+(?:commit|add|checkout|reset|clean)|tee)\b/u.test(value)) return false;
  if (/(?:^|[^2])>(?!&)|>>|\b(?:writeFile|writeFileSync|appendFile|appendFileSync|unlink|unlinkSync|rename|renameSync|rmSync|exec|execSync|spawn|spawnSync)\b/u.test(value)) return false;
  if (/^(?:ls|find|wc|stat|head|tail|cat|rg|grep|sed\s+-n)\b/u.test(value)) return true;
  if (/^node\s+-e\s+/u.test(value) && /readFileSync|statSync|existsSync/u.test(value)) return true;
  return false;
}

function isGlobalSkillBundleProbe(command) {
  return /\b(?:ls|find|tree|rg|grep)\b[\s\S]*(?:\.claude|\.codex|\.zcode)\/skills\/novel-assistant(?:\/|\s|$)/u.test(String(command || ''));
}

function detectWorkflowMutation(command) {
  const value = String(command || '');
  if (!/(?:追踪\/workflow|current-task\.json|task\.json)/u.test(value)) return false;
  if (/workflow-(?:state-machine|runner|supervisor|recover|legacy-migrate)\.js/u.test(value)) return false;
  if (/\b(?:rm|mv)\b[\s\S]*(?:追踪\/workflow|current-task\.json|task\.json)/u.test(value)) return true;
  if (/\bcp\b[\s\S]*(?:追踪\/workflow|current-task\.json|task\.json)(?:\s|$)/u.test(value)) return true;
  if (/\b(?:sed\s+-i|perl\s+-pi)\b[\s\S]*(?:追踪\/workflow|current-task\.json|task\.json)/u.test(value)) return true;
  return /\b(?:python\w*|node)\b[\s\S]*(?:writeFile|writeFileSync|appendFile|appendFileSync|rename|renameSync|unlink|unlinkSync|rmSync)[\s\S]*(?:追踪\/workflow|current-task\.json|task\.json)/u.test(value);
}

function isGeneratedStoryMutator(command) {
  return /\bnode\s+(?:["'][^"']*\/)?scripts\/(?:apply|fix|repair|rewrite|patch)[A-Za-z0-9_.-]*\.(?:c?js|mjs)(?:\s|$)/i.test(command);
}

function detectUnsafe(command) {
  const projectRoot = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  try {
    const checker = require(path.join(projectRoot, 'scripts', 'tool-call-degradation-check.js'));
    const result = checker.detect(command, 'bash', { strict: true });
    if (!result.ok) return result;
  } catch (_) {
    // Keep the local deterministic checks active during legacy runtime migration.
  }
  const findings = [];
  const add = (type) => findings.push({ type });
  if (/\{\d+\.\.\d+\}/.test(command)) add('brace-expansion');
  if (/\$\(/.test(command)) add('command-substitution');
  if (/\b(for|while)\b[\s\S]*\bdo\b[\s\S]*\bdone\b/.test(command)) add('shell-loop');
  if (/(?:&&|\|\||;|\|(?!\|)|(?:^|\s)(?:\d?>|&>))/.test(command)) add('compound-shell');
  return findings.length ? { findings } : null;
}

function replacementReason(command, result) {
  const types = new Set((result.findings || []).map(item => item.type));
  const activeShortStageReason = shortStageReplacementReason();
  if (activeShortStageReason && /(?:正文\.md|素材卡\.md|设定\.md|小节大纲\.md|小节|第\d+节|short-)/u.test(command)) {
    return activeShortStageReason;
  }
  if (looksLikeShortSectionGate(command)) {
    return shortStageReplacementReason() || '短篇当前小节必须使用状态机返回的 execution_command；不要逐个调用检查器、手写 result packet 或读取平台源码。';
  }
  if (looksLikeChapterBatchInspection(command) || types.has('brace-expansion') || types.has('shell-loop')) {
    return '批量章节检查必须改为一条确定性命令：node "$CLAUDE_PROJECT_DIR/scripts/review-batch-evidence-scan.js" --project-root "$CLAUDE_PROJECT_DIR" --range <起章-止章> --write --json。不要缩减任务，也不要再次请求用户授权。';
  }
  if (/\b(grep|rg|find)\b/.test(command)) {
    return '文本检索必须改用一条安全命令：node "$CLAUDE_PROJECT_DIR/scripts/safe-text-search.js" --root "$CLAUDE_PROJECT_DIR" --query <文本> --glob <范围> --json。不要使用 cd、管道或重定向。';
  }
  return '该 Bash 调用包含复合命令、内联脚本、管道、重定向或命令替换。请复用 scripts/ 下的确定性脚本；若无对应脚本，先创建并测试小脚本，再用一条 node 命令继续原任务。';
}

function shortStageReplacementReason() {
  const root = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  try {
    const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
    const workflowId = String(pointer.workflow_id || '');
    if (!workflowId || !/^[A-Za-z0-9_.-]+$/.test(workflowId)) return '';
    const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks', workflowId, 'task.json'), 'utf8'));
    const stage = String(task.current_stage || '');
    const prefix = `node "$CLAUDE_PROJECT_DIR/scripts/`;
    const suffix = `" --project-root "$CLAUDE_PROJECT_DIR" --workflow-id "${workflowId}"`;
    if (stage === 'section_accept_anchor') return `当前阶段是“采用当前小节”，请直接运行：${prefix}short-section-accept-finalize.js${suffix} --apply --json。不要重新统计字数或重跑质量门。`;
    if (['draft_first_section', 'draft_section', 'draft_next_section'].includes(stage)) return `当前阶段是“写当前小节”。只写状态机指定的 draft_target，完成后运行：${prefix}short-section-draft-finalize.js${suffix} --apply --json。不得手写 result packet 或连续写下一节。`;
    if (stage === 'quality_gate' || stage === 'story_value_gate') return `当前阶段是“故事质量门”，请只填写状态机预建的九维证据卡，再运行：${prefix}short-section-quality-gate.js${suffix} --apply --json。不得传裸 pass 或手写回执。`;
    if (stage === 'section_machine_gate') return `当前阶段是“当前小节机器门”，请直接运行：${prefix}short-section-machine-gate.js${suffix} --apply --json。`;
    if (stage === 'section_repair_loop') return `当前阶段是“修订当前小节”。只修改状态机指定的 repair_target，完成后运行：${prefix}short-section-repair-finalize.js${suffix} --apply --json。不得直接跳到机器门。`;
    if (['first_section_brief', 'section_brief', 'next_section_brief'].includes(stage)) return `当前阶段是“生成当前小节 Brief”。先执行状态机返回的 execution_command；若标题未确认，只能运行：${prefix}short-section-title-lock.js" --project-root "$CLAUDE_PROJECT_DIR" --json，展示标题后等待用户。`;
    if (stage === 'full_story_assembly') return `当前阶段是“全篇组装”，请直接运行状态机返回的 short-story-assembly-finalize.js 命令；不得手工拼接正文或手写回执。`;
    if (stage === 'full_story_review') return `当前阶段是“全篇总编辑验收”，先运行 short-story-review-finalize.js 生成证据包；按返回 schema 完成审阅卡后重跑同一命令。不得修改正文或把统计信号直接当成故事结论。`;
    if (stage === 'short_deslop' || stage === 'deslop') return `当前阶段是“全篇表达清理”，只修改状态机指定的暂存稿，再运行 short-story-deslop-finalize.js；不得直接修改 正文.md。`;
    if (stage === 'final_check') return `当前阶段是“最终检查”，请直接运行状态机返回的 short-story-final-check.js；不得使用内联脚本统计、手写 result packet 或修改审计基线。`;
    if (['material_card', 'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline'].includes(stage)) return `当前阶段是“短篇规划制品”，只修改状态机指定的 planning_target，再运行 short-planning-stage-finalize.js；不得直接写正式素材卡、设定或小节大纲。`;
  } catch (_) {
    return '';
  }
  return '';
}

function shortStageCommandMismatch(command) {
  const match = String(command || '').match(/scripts\/(short-section-(?:draft-finalize|repair-finalize|machine-gate|quality-gate|brief-finalize|accept-finalize)\.js)/u);
  if (!match) return '';
  const root = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  try {
    const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
    const workflowId = String(pointer.workflow_id || '');
    if (!workflowId || !/^[A-Za-z0-9_.-]+$/.test(workflowId)) return '';
    const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks', workflowId, 'task.json'), 'utf8'));
    const stage = String(task.current_stage || '');
    const expected = ['draft_first_section', 'draft_section', 'draft_next_section'].includes(stage)
      ? 'short-section-draft-finalize.js'
      : stage === 'section_repair_loop'
        ? 'short-section-repair-finalize.js'
        : stage === 'section_machine_gate'
          ? 'short-section-machine-gate.js'
          : ['quality_gate', 'story_value_gate'].includes(stage)
            ? 'short-section-quality-gate.js'
            : ['first_section_brief', 'section_brief', 'next_section_brief'].includes(stage)
              ? 'short-section-brief-finalize.js'
              : stage === 'section_accept_anchor'
                ? 'short-section-accept-finalize.js'
                : '';
    if (expected && match[1] !== expected) return shortStageReplacementReason();
  } catch (_) {
    return '';
  }
  return '';
}

function looksLikeShortSectionGate(command) {
  if (/(?:短篇|当前小节|第\d+节|草稿_第\d+节|short-section)/u.test(command)) return true;
  const checks = ['check-ai-patterns', 'anti-ai-diagnose', 'story-prose-gate', 'output-pollution-check', 'check-degeneration'];
  return checks.filter((name) => command.includes(name)).length >= 2;
}

function looksLikeChapterBatchInspection(command) {
  return /(?:正文|章节|第\d+章|第0?\d+章|wc\s|check-ai-patterns|check-degeneration|normalize-punctuation)/u.test(command);
}

function isKnownSafeManagedInvocation(command) {
  let value = String(command || '').trim();
  if (!value || /[\n\r;`]|\$\(/u.test(value)) return false;
  if (/\s(?:&&|\|\|)\s/u.test(value)) return false;
  if (/(?:^|[^2])>(?!&)|>>/u.test(value)) return false;

  value = value.replace(/\s+2>&1\s*$/u, '').trim();
  value = value.replace(/\s+2>&1\s*\|\s*(?:head|tail)(?:\s+(?:-\d+|-n\s+\d+|\d+))?\s*$/u, '').trim();
  value = value.replace(/\s*\|\s*(?:head|tail)(?:\s+(?:-\d+|-n\s+\d+|\d+))?\s*$/u, '').trim();
  if (/[|><`]/u.test(value) || /\$\(/u.test(value)) return false;

  value = value.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)*/u, '');
  const match = value.match(/^node\s+(?:"([^"]+)"|'([^']+)'|(\S+))(?:\s|$)/u);
  return Boolean(match && SAFE_SCRIPTS.has(path.basename(match[1] || match[2] || match[3] || '')));
}

function isLegacyManagedWorkingDirectoryInvocation(command) {
  const value = String(command || '').trim();
  if (!value || /[\n\r;`]|\$\(|\|\||\|(?!\|)|(?:^|\s)(?:\d?>|&>)/u.test(value)) return false;
  const match = value.match(/^cd\s+(?:"[^"]+"|'[^']+'|[^\s&|;<>`]+)\s+&&\s+([\s\S]+)$/u);
  return Boolean(match && isKnownSafeManagedInvocation(match[1]));
}

function isKnownSafeCommand(command) {
  if (/[\n\r;&|><`]|\$\(|\{\d+\.\.\d+\}/.test(command)) return false;
  const match = command.trim().match(/^node\s+(?:"([^"]+)"|'([^']+)'|(\S+))/);
  if (!match) return false;
  return SAFE_SCRIPTS.has(path.basename(match[1] || match[2] || match[3] || ''));
}

function allow(reason) {
  emit({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow', permissionDecisionReason: reason } });
  return 0;
}

function deny(reason) {
  emit({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } });
  return 0;
}

function readPayload() {
  const raw = process.env.CLAUDE_TOOL_INPUT || readStdin();
  try { return JSON.parse(raw || '{}'); } catch (_) { return {}; }
}

function readStdin() {
  try { return require('fs').readFileSync(0, 'utf8'); } catch (_) { return '';
  }
}

function findString(value, names) {
  if (Array.isArray(value)) {
    for (const item of value) { const found = findString(item, names); if (found) return found; }
    return '';
  }
  if (!value || typeof value !== 'object') return '';
  for (const name of names) if (typeof value[name] === 'string' && value[name].trim()) return value[name].trim();
  for (const child of Object.values(value)) { const found = findString(child, names); if (found) return found; }
  return '';
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

process.exitCode = main();
