'use strict';
// scripts/lib/interactive-tool-budget.js
//
// Task 4: 交互式 Claude Code 写作模式的动态工具预算熔断核心库。
//
// 设计目标(事故根因):
//   写正文阶段转换失败后,Claude Code 会反复读平台源码、写临时 debug 脚本、改受管 scripts/。
//   预算熔断的核心是"写作模式 vs 平台诊断"的二元划分:
//     (a) 写作模式下平台源码诊断动作许可数 = 0
//     (b) 正常写作动作放行
//
// 职责划分:
//   - 本库只负责"平台诊断 + 受管源码保护 + 源码读取节流"。
//   - 转换失败恢复(recovery_count/exhausted/pause_at_checkpoint)由
//     scripts/lib/workflow-stage-controller.js 的 max_retry_budget 负责,
//     本库不重复实现 controller 失败重试逻辑。
//
// Fail-open 原则:找不到任务 / 非写作项目 / 库加载失败时 allow,不阻断普通项目。
// 受管源码保护已有 canonical-write-guard.js 负责;本库只管写作模式下的额外约束。

const fs = require('fs');
const path = require('path');

// 写作类 workflow_type。任何不属于此集合的 workflow_type(如 scan/trend_analyze/
// deslop/cover/...) 都不算"写作模式",平台诊断放行。
const WRITING_WORKFLOW_TYPES = new Set([
  'short_write',
  'long_write',
  'private_short_startup',
  'long_startup',
]);

// 写作类正文生成/草稿阶段的 stage id 正则。涵盖短篇与长篇的 draft/prose/brief 类阶段。
// 注意:仅匹配 stage id 本身(如 draft_next_section / prose / chapter_brief),
// 不匹配任意路径。current_section_draft 是 section_machine_gate 的私有草稿状态
// (见 workflow-registry.json required_inputs),同样属于写作阶段。
const WRITING_STAGE_PATTERN = /(?:^|_)(draft|prose|section_brief|chapter_brief|next_section_brief|first_section_brief|current_section_draft|draft_first_section|draft_section|draft_next_section|section_machine_gate|section_repair_loop|quality_gate|story_value_gate|feedback_apply_patch|section_accept_anchor|brief_review|chapter_commit|milestone_review)(?:_|$)/;

// 受管平台源码白名单(显式枚举,作为补充)。主体判断改用 isManagedSourceFile()
// 路径模式,白名单仅用于额外兜底——避免硬编码列表遗漏新增的 workflow-*/runtime-*/memory-*
// 运行时库(见 Fix 3)。
const MANAGED_SOURCE_FILES = new Set([
  'workflow-state-machine.js',
  'workflow-stage-controller.js',
  'interactive-tool-budget.js',
  'workflow-transition-service.js',
  'workflow-state-store.js',
  'workflow-template-registry.js',
  'workflow-host-adapters.js',
  'workflow-runner-execution.js',
  'novel-assistant-sync-runtime.js',
  'runtime-guard-validate.js',
  'tool-call-degradation-check.js',
  'canonical-write-policy.js',
  'runtime-safe-fs.js',
  'runtime-managed-files.js',
  'context-budget.js',
]);

// scripts/ 顶层的生产扫描工具(写作流程依赖,不算受管源码、不算平台 debug)。
const PRODUCTION_TOOL_ALLOWLIST = new Set([
  'scan-json-validate.js',
  'scan-download-hints.js',
  'scan-artifact-build.js',
]);

// 平台诊断脚本前缀正则:debug-*/find-*/inspect-* 一律禁止;
// 扫描脚本 scan-* 同理。覆盖常见脚本扩展名 + 无扩展名(防止 debug-reconcile.py /
// 无扩展名 debug-foo 漏检)。scan 白名单(production allowlist)放行。
// 扩展名白名单:js/cjs/mjs/ts/cts/mts/sh/py/rb/pl/pm/php(bash/node/python/ruby/perl/php 脚本)。
const PLATFORM_DEBUG_SCRIPT_PATTERN = /^scripts\/(?:debug|find|inspect)-[A-Za-z0-9_.\/-]*\.(?:c?js|mjs|ts|cts|mts|sh|py|rb|pl|pm|php)$/i;
const PLATFORM_DEBUG_NOEXT_PATTERN = /^scripts\/(?:debug|find|inspect)-[A-Za-z0-9_.\/-]+$/i;
const PLATFORM_SCAN_SCRIPT_PATTERN = /^scripts\/scan-[A-Za-z0-9_.-]*\.(?:c?js|mjs|ts|cts|mts|sh|py|rb|pl|pm|php)$/i;
const PLATFORM_SCAN_NOEXT_PATTERN = /^scripts\/scan-[A-Za-z0-9_.\/-]+$/i;
const SCAN_ALLOWLIST = PRODUCTION_TOOL_ALLOWLIST;

// 写作模式下允许读取的源码读取连续阈值。超过即 deny。
const DEFAULT_PLATFORM_SOURCE_READ_CAP = 0;

const APPROVED_RUNTIME_COMMANDS = Object.freeze([
  'workflow-entry-guard.js',
  'workflow-task-inbox.js',
  'workflow-state-machine.js',
  'workflow-stage-controller.js',
  'short-section-draft-finalize.js',
  'short-section-repair-finalize.js',
  'short-section-machine-gate.js',
  'short-section-quality-gate.js',
  'short-section-brief-finalize.js',
  'short-section-title-lock.js',
  'short-section-accept-finalize.js',
  'long-chapter-machine-gate.js',
  'long-chapter-quality-gate.js',
]);

// 计算最近平台源码读取事件时回看的事件数(性能与准确度的折中)。
const RECENT_EVENT_WINDOW = 20;

// ============================================================================
// buildStageToolBudget:从任务契约 + stage 定义构造预算
// ============================================================================

function buildStageToolBudget(task, stageDef, options = {}) {
  const safeTask = task || {};
  const isWriting = isWritingStage(safeTask, stageDef);
  const guard = (safeTask.runtime_guard || {});
  const retryBudget = guard.max_retry_budget || {};
  return {
    writing_mode: isWriting,
    // 平台诊断动作(写 debug 脚本 / 改受管源码)在写作模式下许可数为 0。
    platform_debug_allowance: isWriting ? 0 : Infinity,
    // controller 失败恢复次数(仅用于报告;实际执行在 controller)。
    controller_recovery_allowance: Number(retryBudget.same_failure || 1),
    // 平台源码连续读取阈值:超过即 deny。
    platform_source_read_cap: isWriting
      ? nonNegativeInteger(options.platform_source_read_cap, DEFAULT_PLATFORM_SOURCE_READ_CAP)
      : Infinity,
    on_exhausted: retryBudget.on_exhausted || 'pause_at_checkpoint',
  };
}

// 判断当前任务是否处于"写作模式":
//   workflow_type 必须是写作类(short_write/long_write/...) 且
//   current_stage 匹配写作类正文生成阶段。
function isWritingStage(task, stageDef) {
  const safeTask = task || {};
  const workflowType = String(safeTask.workflow_type || '');
  if (!WRITING_WORKFLOW_TYPES.has(workflowType)) return false;
  // current_stage 优先来自 task,缺失时从 stageDef.id 取。
  const stageId = String(safeTask.current_stage || (stageDef && stageDef.id) || '');
  if (!stageId) return false;
  return WRITING_STAGE_PATTERN.test(stageId);
}

// ============================================================================
// evaluateToolCall:评估单次工具调用,返回 allow | pause
// ============================================================================

function evaluateToolCall({ task, stage, toolName, toolInput, priorEvents, projectRoot }) {
  const safeTask = task || {};
  const safeInput = toolInput || {};
  const budget = buildStageToolBudget(safeTask, stage);

  // 非写作模式:平台诊断放行(本库不约束)。
  if (!budget.writing_mode) {
    return { decision: 'allow', code: 'non_writing_mode', reason: '非写作模式,平台诊断放行。' };
  }

  // 1. 平台诊断写入(debug-*/scan-*/find-*/inspect-* 脚本) -> pause
  //    包括 Bash 命令通过重定向/tee/sed -i/node writeFileSync 等方式写这些脚本。
  const platformDebug = isPlatformDebugWrite(toolName, safeInput, projectRoot);
  if (platformDebug) {
    return {
      decision: 'pause',
      code: 'blocked_writing_mode_platform_debug',
      reason: '写作模式下禁止创建平台排障脚本(debug-*/scan-*/find-*/inspect-*)。请从最后可信断点恢复,使用受控链路而非临时脚本。',
      target: platformDebug,
    };
  }

  // 2. 受管源码修改 -> pause
  //    包括 Bash 命令通过重定向/tee/sed -i/cp/mv/node writeFileSync 等方式写受管源码。
  const managedMutation = isManagedSourceMutation(toolName, safeInput, projectRoot);
  if (managedMutation) {
    return {
      decision: 'pause',
      code: 'blocked_writing_mode_platform_debug',
      reason: '写作模式下禁止修改受管运行时源码(scripts/ 下状态机/控制器/预算库等)。请从最后可信断点恢复。',
      target: managedMutation,
    };
  }

  // 3. 连续平台源码读取超 cap -> pause
  if (isPlatformSourceRead(toolName, safeInput)) {
    const recent = countRecentPlatformReads(priorEvents || []);
    if (recent >= budget.platform_source_read_cap) {
      return {
        decision: 'pause',
        code: 'blocked_interactive_tool_budget_exhausted',
        reason: `连续读取平台源码 ${recent} 次已达上限(${budget.platform_source_read_cap})。疑似失控排障。请从最后可信断点恢复,改用受控脚本或停止诊断。`,
        budget,
      };
    }
  }

  // 正常写作动作放行。
  return { decision: 'allow', code: 'writing_mode_allow', reason: '写作模式下正常写作动作放行。' };
}

// ----------------------------------------------------------------------------
// 分类谓词
// ----------------------------------------------------------------------------

// 平台诊断写入:
//   - Write/Edit/MultiEdit 到 scripts/(debug|scan|find|inspect)-* 脚本
//   - Bash 命令通过重定向/tee/heredoc/sed -i/cp/mv/node writeFileSync 等方式写这些脚本
// scan 白名单(scan-json-validate 等写作依赖脚本)放行。
function isPlatformDebugWrite(toolName, toolInput, projectRoot) {
  if (isMutationTool(toolName)) {
    const rel = relativeProjectPath(toolInput.file_path || toolInput.filePath, projectRoot);
    if (rel && isPlatformDebugScript(rel)) return rel;
    return null;
  }
  if (toolName === 'Bash') {
    const cmd = String((toolInput && toolInput.command) || '');
    const hit = detectBashFileMutation(cmd, projectRoot, { kind: 'platform_debug' });
    return hit || null;
  }
  return null;
}

// 受管源码修改:
//   - Write/Edit/MultiEdit 到 scripts/ 顶层 .js(非生产工具白名单)、scripts/lib/**.js、
//     .claude/hooks/**
//   - Bash 命令通过重定向/tee/heredoc/sed -i/cp/mv/node writeFileSync 等方式写这些路径
// 受管判断主体走 isManagedSourceFile() 路径模式,避免硬编码列表遗漏(见 Fix 3)。
function isManagedSourceMutation(toolName, toolInput, projectRoot) {
  if (isMutationTool(toolName)) {
    const rel = relativeProjectPath(toolInput.file_path || toolInput.filePath, projectRoot);
    if (!rel) return null;
    if (isManagedSourceFile(rel)) return rel;
    return null;
  }
  if (toolName === 'Bash') {
    const cmd = String((toolInput && toolInput.command) || '');
    const hit = detectBashFileMutation(cmd, projectRoot, { kind: 'managed' });
    return hit || null;
  }
  return null;
}

// 平台源码读取:
//   Bash 且 command 含 (find|grep|rg|cat|head|tail|sed|awk) ... scripts/
//   或 Read 且 file_path 在 scripts/ 下。
function isPlatformSourceRead(toolName, toolInput) {
  if (toolName === 'Bash') {
    const cmd = String((toolInput && toolInput.command) || '');
    if (isApprovedRuntimeCommand(cmd)) return false;
    if (/\b(?:find|grep|rg|cat|head|tail|sed|awk|ls)\b[\s\S]*(?:^|[\s"'])[^\s"']*scripts(?:\/|[\s"']|$)/m.test(cmd)) return true;
    if (/safe-text-search\.js[\s\S]*--root[=\s]+["']?[^\s"']*\/skills\/novel-assistant\/scripts(?:\/|["'\s]|$)/.test(cmd)) return true;
    if (/\/(?:\.claude|\.codex|\.agents)\/skills\/novel-assistant\/scripts\/lib\//.test(cmd)) return true;
    if (/\b(?:workflow-state-machine|workflow-runner|workflow-stage-controller)\.js\b[\s\S]*(?:--help|help\b)/.test(cmd)) return true;
    return false;
  }
  if (toolName === 'Read') {
    const raw = String((toolInput && (toolInput.file_path || toolInput.filePath)) || '').replace(/\\/g, '/');
    const rel = relativeProjectPath(raw);
    return Boolean((rel && rel.startsWith('scripts/')) || /\/(?:\.claude|\.codex|\.agents)\/skills\/novel-assistant\/scripts\//.test(raw));
  }
  return false;
}

function isApprovedRuntimeCommand(command) {
  const cmd = String(command || '');
  const matches = [...cmd.matchAll(/(?:^|[\s"'\/])([A-Za-z0-9_.-]+\.js)(?=[\s"']|$)/g)].map((match) => match[1]);
  if (matches.length !== 1 || !APPROVED_RUNTIME_COMMANDS.includes(matches[0])) return false;
  if (matches[0] === 'workflow-state-machine.js') {
    return /\b(?:resolve-action|apply-result|inspect|next-candidates)\b/.test(cmd)
      || /\bworkflow-state-machine\.js\b[\s\S]*--project-root\b/.test(cmd)
      || /\b(?:--help|help)\b/.test(cmd);
  }
  return true;
}

function nonNegativeInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : fallback;
}

function isMutationTool(toolName) {
  return toolName === 'Write' || toolName === 'Edit' || toolName === 'MultiEdit';
}

// 判断路径是否为平台 debug/scan/find/inspect 脚本(支持带扩展名与无扩展名)。
function isPlatformDebugScript(rel) {
  if (PLATFORM_DEBUG_SCRIPT_PATTERN.test(rel)) return true;
  if (PLATFORM_DEBUG_NOEXT_PATTERN.test(rel)) return true;
  if (PLATFORM_SCAN_SCRIPT_PATTERN.test(rel)) {
    const base = path.posix.basename(rel);
    if (!SCAN_ALLOWLIST.has(base)) return true;
    return false;
  }
  if (PLATFORM_SCAN_NOEXT_PATTERN.test(rel)) {
    // 无扩展名 scan-* 一律视为平台脚本(scan-foo / scan-foo.bar 都不在白名单内)。
    return true;
  }
  return false;
}

// 判断相对路径是否为受管运行时源码。用路径模式判断,比硬编码文件名集合稳健得多——
// 自动覆盖所有 workflow-*/runtime-*/memory-* 等运行时库,即便后续新增也不漏。
function isManagedSourceFile(rel) {
  const normalized = String(rel || '').replace(/\\/g, '/');
  if (!normalized || normalized.startsWith('../')) return false;
  // scripts/ 顶层 .js(排除生产扫描工具白名单)
  if (/^scripts\/[^/]+\.js$/.test(normalized)) {
    const basename = normalized.split('/').pop();
    if (!PRODUCTION_TOOL_ALLOWLIST.has(basename)) return true;
  }
  // scripts/lib/ 下所有 .js(运行时库:状态机/控制器/预算/registry/memory/...)
  if (/^scripts\/lib\/[^/]+\.js$/.test(normalized)) return true;
  // .claude/hooks/ 下任何 hook 的修改都属于受管源码
  if (/^\.claude\/hooks\//.test(normalized)) return true;
  // 显式白名单兜底(MANAGED_SOURCE_FILES 集合)
  const basename = normalized.split('/').pop();
  if (MANAGED_SOURCE_FILES.has(basename) && normalized.startsWith('scripts/')) return true;
  return false;
}

// ----------------------------------------------------------------------------
// Bash 写文件绕过检测
// ----------------------------------------------------------------------------

// 从 Bash command 字符串中检测"写文件到受保护路径"的命令,返回命中的相对路径(用于 pause.target)。
// 不必完美解析 shell 语法,覆盖常见写文件模式即可:
//   - 重定向 `> scripts/...` 或 `>> scripts/...`
//   - tee scripts/...
//   - heredoc `cat > scripts/... <<EOF` / `cat >> scripts/...`
//   - sed -i ... scripts/...(原地编辑)
//   - cp/mv ... scripts/...(拷入/移动入受管目录)
//   - node -e "...writeFileSync('scripts/..."/writeFile('scripts/...") 等内联 JS 写
//   - printf/echo > scripts/...
//
// 选项:
//   - kind: 'platform_debug' 只看平台 debug 脚本;'managed' 只看受管源;undefined 两者都看
//   - projectRoot: 用于把命令里的相对/绝对路径归一为项目相对路径
function detectBashFileMutation(command, projectRoot, options = {}) {
  const cmd = String(command || '');
  if (!cmd) return '';
  const kind = options && options.kind;
  const candidates = extractTargetPathsFromBash(cmd);
  for (const raw of candidates) {
    const rel = relativeProjectPath(raw, projectRoot);
    if (!rel) continue;
    if (kind === 'platform_debug') {
      if (isPlatformDebugScript(rel)) return rel;
    } else if (kind === 'managed') {
      if (isManagedSourceFile(rel)) return rel;
    } else {
      if (isPlatformDebugScript(rel) || isManagedSourceFile(rel)) return rel;
    }
  }
  return '';
}

// 从 Bash command 字符串里抽取所有可能的目标写入路径。覆盖常见写文件模式。
// 不做完整 shell 语法解析,只识别写入意图明确的模式。
//
// 检测的写入形式:
//   - 重定向 `> path` / `>> path` / `1> path` / `2> path`(排除 `2>&1` 之类无文件操作数)
//   - tee path / tee -a path
//   - heredoc `cat > path <<EOF` / `cat >> path <<EOF`(被重定向模式覆盖)
//   - sed -i ... path(原地编辑,目标文件是最后一个参数)
//   - cp/mv/install src ... dst(末尾参数为写入目标)
//   - node -e "...writeFileSync('path'...)" / writeFile('path'...) 等内联 JS 写
function extractTargetPathsFromBash(cmd) {
  const paths = [];
  let m;
  // 1. 重定向 `> path` / `>> path` / `1> path` / `2> path`(排除 `2>&1` 这类无操作数)
  //    数字前缀仅紧贴 > 时算重定向(避免匹配 "1>" 在 "1 >= 2" 这种比较里)。
  const redirectRe = /(?:(\d)?)>>?\s*((?!&)\S+)/g;
  while ((m = redirectRe.exec(cmd)) !== null) {
    paths.push(stripQuotes(m[2]));
  }
  // 2. tee path / tee -a path / tee -ai path
  const teeRe = /\btee\s+(?:-[a-zA-Z]+\s+)*(\S+)/g;
  while ((m = teeRe.exec(cmd)) !== null) {
    paths.push(stripQuotes(m[1]));
  }
  // 3. sed -i ... path(原地编辑:命令行最后一个非 flag token 是被编辑的文件)
  //    只在出现 -i 标志(可能带可选备份后缀,如 -i.bak 或 -i '')时触发。
  const sedIRe = /\bsed\b[\s\S]*?\s-i(?:\.?[A-Za-z0-9]*)?(?:\s|$)/g;
  let sedMatch;
  while ((sedMatch = sedIRe.exec(cmd)) !== null) {
    const tail = cmd.slice(sedMatch.index);
    const target = lastNonFlagToken(tail);
    if (target) paths.push(stripQuotes(target));
  }
  // 4. cp/mv/install src ... dst(末尾参数为写入目标)
  const cpRe = /\b(?:cp|mv|install)\b[\s\S]*$/g;
  let cpMatch;
  while ((cpMatch = cpRe.exec(cmd)) !== null) {
    const target = lastNonFlagToken(cpMatch[0]);
    if (target) paths.push(stripQuotes(target));
  }
  // 5. node -e "...writeFileSync('path'...)" / writeFile('path'...) 等内联 JS 写
  //    同时处理转义引号场景(node -e "require(\"fs\").writeFileSync(\"path\", ...)")
  //    字符类里的 `\\` 用于匹配路径前的转义反斜杠(可选)。
  const nodeWriteRe = /\bwrite(?:File|FileSync)\s*\(\s*\\?['"`]([^'"`\s)\\]+?)\\?['"`]/g;
  while ((m = nodeWriteRe.exec(cmd)) !== null) {
    paths.push(m[1]);
  }
  return paths;
}

// 取一段 shell 片段的最后一个非 flag token(粗略:不以下一阶段 flag 开头)。
// 用于 cp/mv/sed -i 的目标参数提取。仅作启发式,不必精确处理管道/重定向。
function lastNonFlagToken(fragment) {
  // 截断到第一个未配对引号前的 pipe / & / ; 之前(保守)
  const stop = fragment.search(/[|;&]\s/);
  const slice = stop > 0 ? fragment.slice(0, stop) : fragment;
  const tokens = slice.match(/(?:"[^"]*"|'[^']*'|[^\s'"]+)/g) || [];
  for (let i = tokens.length - 1; i >= 0; i -= 1) {
    const t = stripQuotes(tokens[i]);
    // 跳过明显的 flag(以 - 开头)
    if (t.startsWith('-')) continue;
    // 跳过 sed 表达式(s/.../.../ 或 y/.../.../)
    if (/^[sy]:?\/.*\//.test(t) || /^s\/.*\/.*\/[a-zA-Z]*$/.test(t)) continue;
    return t;
  }
  return '';
}

function stripQuotes(s) {
  const v = String(s || '').trim();
  if (v.length >= 2) {
    const first = v[0];
    const last = v[v.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'") || (first === '`' && last === '`')) {
      return v.slice(1, -1);
    }
  }
  return v;
}

// 计算 priorEvents 中"最近的"平台源码读取次数(只在最近 RECENT_EVENT_WINDOW 条里数)。
function countRecentPlatformReads(priorEvents) {
  if (!Array.isArray(priorEvents)) return 0;
  const recent = priorEvents.slice(-RECENT_EVENT_WINDOW);
  let count = 0;
  for (const ev of recent) {
    if (!ev) continue;
    if (ev.reason === 'platform_source_read' || ev.category === 'platform_source_read') {
      count += 1;
    }
  }
  return count;
}

// ============================================================================
// 工具:把绝对/相对路径归一为相对项目根的 POSIX 路径
// ============================================================================

function relativeProjectPath(target, projectRoot) {
  const value = String(target || '').trim();
  if (!value) return '';
  const root = projectRoot || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const normalized = value.replace(/\\/g, '/');
  const absolute = path.isAbsolute(normalized)
    ? path.resolve(normalized)
    : path.resolve(root, normalized);
  const rel = path.relative(path.resolve(root), absolute);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return '';
  return rel.split(path.sep).join('/');
}

// ============================================================================
// 事件账本:tool-events.jsonl 读写
// ============================================================================

function ledgerPath(projectRoot, workflowId) {
  return path.join(projectRoot, '追踪', 'workflow', 'tasks', String(workflowId), 'tool-events.jsonl');
}

// 读账本为事件数组。缺失/损坏 -> 返回空数组(永不抛错,fail-open)。
function readLedger(projectRoot, workflowId) {
  const file = ledgerPath(projectRoot, workflowId);
  try {
    if (!fs.existsSync(file)) return [];
    const text = fs.readFileSync(file, 'utf8');
    const events = [];
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try { events.push(JSON.parse(trimmed)); } catch (_) { /* skip malformed */ }
    }
    return events;
  } catch (_) {
    return [];
  }
}

// 追加一条事件到账本。目录不存在 -> 创建。失败 -> 静默(fail-open,不阻断主流程)。
function appendLedger(projectRoot, workflowId, event) {
  try {
    const file = ledgerPath(projectRoot, workflowId);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const line = `${JSON.stringify({ ts: new Date().toISOString(), ...event })}\n`;
    fs.appendFileSync(file, line, { encoding: 'utf8' });
  } catch (_) {
    // 静默:账本写入失败不应阻断工具调用决策本身。
  }
}

module.exports = {
  buildStageToolBudget,
  evaluateToolCall,
  isWritingStage,
  isPlatformDebugWrite,
  isManagedSourceMutation,
  isPlatformSourceRead,
  isPlatformDebugScript,
  isManagedSourceFile,
  detectBashFileMutation,
  extractTargetPathsFromBash,
  readLedger,
  appendLedger,
  ledgerPath,
  // 常量也导出供测试/CLI 引用。
  WRITING_WORKFLOW_TYPES,
  WRITING_STAGE_PATTERN,
  MANAGED_SOURCE_FILES,
  PRODUCTION_TOOL_ALLOWLIST,
  SCAN_ALLOWLIST,
  PLATFORM_DEBUG_SCRIPT_PATTERN,
  PLATFORM_DEBUG_NOEXT_PATTERN,
  PLATFORM_SCAN_SCRIPT_PATTERN,
  PLATFORM_SCAN_NOEXT_PATTERN,
  DEFAULT_PLATFORM_SOURCE_READ_CAP,
};
