'use strict';

// Utility helpers extracted from workflow-state-machine.js.
//
// These functions have no module-state dependency (ACTIVE_TEMPLATES / registries),
// no __dirname assumption, and no calls into the state machine's internal function
// graph. They are deterministic: same inputs always produce same outputs.
//
// IMPORTANT: some functions directly mutate the caller-provided `task` object
// (e.g. synchronizeShortUnitScope, markShortMemoryMigrationRefreshed,
// preservePreviousStageAttempt, reopenShortTaskForFeedback,
// synchronizeShortWholeStoryScope). The state machine calls them at points
// where mutating the in-memory task is the intended behavior, then persists the
// task. Do not relocate these calls after persistence, or the in-memory and
// on-disk states will diverge.

const crypto = require('crypto');
const path = require('path');
const fs = require('fs');

function readText(file) {
  try {
    return require('fs').readFileSync(file, 'utf8');
  } catch (_) {
    return '';
  }
}

function rel(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function positiveContextChars(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 0;
}

function hasActiveWorkflowStatus(status) {
  return !['completed', 'completed_verified', 'done', 'closed', 'cancelled', 'canceled'].includes(String(status || '').toLowerCase());
}

function createStageAttemptId(workflowId, stageId) {
  return `sa-${String(workflowId || 'workflow')}-${String(stageId || 'stage')}-${crypto.randomBytes(4).toString('hex')}`;
}

function arrayOrEmpty(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeContentHash(value) {
  return String(value || '').replace(/^sha256:/, '');
}

function sameContractValue(actual, expected) {
  if (actual && typeof actual === 'object') return JSON.stringify(actual) === JSON.stringify(expected);
  return String(actual) === String(expected);
}

function chineseNumeralValue(value) {
  const digits = { 零: 0, 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const units = { 十: 10, 百: 100 };
  let total = 0;
  let current = 0;
  for (const char of String(value || '')) {
    if (Object.prototype.hasOwnProperty.call(digits, char)) current = digits[char];
    else if (units[char]) {
      total += (current || 1) * units[char];
      current = 0;
    } else return 0;
  }
  return total + current;
}

function normalizedChapterIdentity(value) {
  const match = String(value || '').trim().match(/^(?:第\s*)?0*(\d+)\s*(?:章)?$/);
  return match ? Number(match[1]) : 0;
}

function isConsoleErrorStatus(status) {
  const value = String(status || '');
  if (!value.startsWith('blocked_')) return false;
  const handledWorkflowStates = new Set([
    'blocked_non_head_branch_projection',
    'blocked_selection_resolved',
    'blocked_selection_expired',
    'blocked_missing_visible_choice_binding',
    'blocked_stale_visible_choice',
    'blocked_visible_choice_hash_mismatch',
    'blocked_pending_action_project_mismatch',
    'blocked_stage_already_running',
    'blocked_free_text_disabled',
    'blocked_short_section_title_unconfirmed',
    'blocked_short_feedback_unreconciled',
    'blocked_short_section_plan_missing',
    'blocked_short_section_plan_conflict',
    'blocked_short_section_outside_plan',
    'blocked_short_full_story_assembly_missing',
    'blocked_longform_lifecycle_migration_required',
  ]);
  return !handledWorkflowStates.has(value);
}

function normalizeLifecycle(task) {
  const now = new Date().toISOString();
  const lifecycle = task.lifecycle || {};
  return {
    status: lifecycle.status || (task.status === 'completed' ? 'completed' : 'active'),
    started_at: lifecycle.started_at || task.created_at || now,
    updated_at: lifecycle.updated_at || task.updated_at || now,
    completed_at: lifecycle.completed_at || '',
    user_goal: lifecycle.user_goal || task.user_goal || '',
    scope: lifecycle.scope || task.scope || '',
    previous_workflow_id: lifecycle.previous_workflow_id || '',
    switch_reason: lifecycle.switch_reason || '',
  };
}

function buildConfirmationContext(task, selected, stageId, selectedAt) {
  return {
    status: 'confirmed',
    workflow_id: task.workflow_id || '',
    workflow_type: task.workflow_type || '',
    stage_id: stageId,
    step_id: stageId,
    selection_id: selected.selection_id || '',
    selected_number: selected.selected_number,
    selected_action_id: selected.action_id || '',
    selected_at: selectedAt,
    confirmed_at: selectedAt,
    expires_at: selected.selection_expires_at || '',
    visible_choice_hash: selected.visible_choice_hash || '',
    confirmation_token: crypto.randomBytes(24).toString('hex'),
    operation: task.workflow_type === 'cover' ? (task.cover_operation || 'generate') : '',
    target_scope: selected.target_scope || task.scope || '',
    target_files: Array.isArray(selected.target_files) ? selected.target_files.slice() : [],
  };
}

function resolveSafeProjectFile(projectRoot, filePath) {
  if (!filePath) return '';
  const root = path.resolve(projectRoot);
  const file = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(root, filePath);
  if (file === root || !file.startsWith(`${root}${path.sep}`)) return '';
  try {
    const realRoot = fs.realpathSync(root);
    let existing = file;
    while (!fs.existsSync(existing) && existing !== root) existing = path.dirname(existing);
    const realExisting = fs.realpathSync(existing);
    if (realExisting !== realRoot && !realExisting.startsWith(`${realRoot}${path.sep}`)) return '';
  } catch (_) {
    return '';
  }
  return file;
}

function readJsonlRecords(file) {
  try {
    return fs.readFileSync(file, 'utf8')
      .split(/\r?\n/u)
      .filter(line => line.trim())
      .map(line => JSON.parse(line))
      .filter(record => record && typeof record === 'object');
  } catch (_) {
    return [];
  }
}

function infoSourceSelectionCards(root, task) {
  if (String((task || {}).current_stage || '') !== 'info_source_selection') return [];
  const file = path.join(root, '追踪/private-short-extension/cards/info-source-cards.jsonl');
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return [];
  const cards = readJsonlRecords(file)
    .filter(card => ['write', 'backup'].includes(String(card.verdict || '')))
    .filter(card => !['discarded', 'used'].includes(String(card.pool_status || '')));
  cards.sort((left, right) => {
    const byScore = infoSourceMaterialScore(right) - infoSourceMaterialScore(left);
    if (byScore !== 0) return byScore;
    const verdictRank = value => String(value.verdict || '') === 'write' ? 0 : 1;
    const byVerdict = verdictRank(left) - verdictRank(right);
    if (byVerdict !== 0) return byVerdict;
    return String(left.info_id || '').localeCompare(String(right.info_id || ''), 'zh-Hans-CN');
  });
  return cards.slice(0, 12).map((card, index) => ({ ...card, display_no: index + 1 }));
}

function reopenShortTaskForFeedback(task, now = new Date().toISOString()) {
  task.status = 'running';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.status = 'active';
  task.lifecycle.updated_at = now;
  task.lifecycle.completed_at = '';
  task.recommended_next = [];
  if (task.unit_lifecycle && typeof task.unit_lifecycle === 'object') {
    task.unit_lifecycle = {
      ...task.unit_lifecycle,
      status: 'active',
      updated_at: now,
    };
  }
}

function shortSettingCandidateView(root, task, options = {}) {
  const candidate = task.short_setting_candidate && typeof task.short_setting_candidate === 'object'
    ? task.short_setting_candidate
    : {};
  const relative = String(candidate.path || '');
  const file = resolveSafeProjectFile(root, relative);
  const source = file && fs.existsSync(file) && fs.statSync(file).isFile()
    ? fs.readFileSync(file, 'utf8').trim()
    : '';
  const limit = Math.max(600, Number(options.previewLimit || 1800));
  return {
    status: source ? String(candidate.status || 'ready') : 'missing',
    path: relative,
    sha256: String(candidate.sha256 || ''),
    revision: Number(candidate.revision || 0),
    preview: source.slice(0, limit),
    preview_truncated: source.length > limit,
  };
}

function synchronizeShortWholeStoryScope(task, stageId) {
  task.scope = '全篇';
  task.lifecycle = normalizeLifecycle(task);
  task.lifecycle.scope = '全篇';
  task.lifecycle.updated_at = new Date().toISOString();
  task.unit_lifecycle = {
    ...(task.unit_lifecycle || {}),
    unit_type: 'story',
    status: 'active',
    current_scope: '全篇',
    current_stage: String(stageId || task.current_stage || ''),
    updated_at: new Date().toISOString(),
  };
}

function inferFreeTextClassification(text) {
  const normalized = text.replace(/\s+/g, ' ');
  const scopeMatch = normalized.match(/(\d+\s*[-到至]\s*\d+)/);
  const targetScope = scopeMatch ? scopeMatch[1].replace(/\s+/g, '') : '';
  if (/(?:重新|重来|再|换一批|作废|不要|丢弃).{0,12}(?:抓取|获取|搜|资讯|热点|素材)|(?:资讯|热点|素材).{0,12}(?:重新抓取|重抓|换一批|作废|不要了)/.test(normalized)) {
    return {
      classification: 'restart_short_info_discovery',
      recommended_action: 'restart_short_info_discovery',
      suggested_workflow_type: 'short_write',
      target_scope: '',
      reason: '用户明确要求废弃当前资讯选择并重新发现热点；旧素材保留为历史，不进入后续上下文。',
    };
  }
  if (/先别|不要继续|换个任务|新任务|改成|转去|先审|审阅|审查/.test(normalized) && /(审阅|审查|拆文|写|短篇|长篇|去\s*AI|下载|导入)/.test(normalized)) {
    return {
      classification: 'switch_intent',
      recommended_action: 'call_switch_intent',
      suggested_workflow_type: suggestedWorkflowType(normalized),
      target_scope: targetScope,
      reason: '用户输入包含明显的新任务或切换意图；不得绑定到旧数字候选。',
    };
  }
  if (isStructuralScopeChange(normalized)) {
    return {
      classification: 'scope_change',
      recommended_action: 'route_upstream_replan',
      suggested_workflow_type: 'long_write',
      target_scope: targetScope,
      reason: '用户改变章/节数量、边界或顺序；需要先回到计划锁定和影响审计。',
    };
  }
  if (/不合理|不对|跑题|人物|动机|逻辑|重做|重写|回炉|反馈|修改|更新|调整|改一下|改为|改成|换成|替换|删除|删掉|不像人|不好看|没爽点|太平|太AI|AI味/.test(normalized)
    || /第\s*\d+\s*节[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(normalized)
    || /(?:开头|结尾|这一节)[^。；]{0,80}(?:可以|建议|应该|改为|加入|增加)/.test(normalized)) {
    return {
      classification: 'current_artifact_feedback',
      recommended_action: 'route_feedback_before_execution',
      suggested_workflow_type: '',
      target_scope: targetScope,
      reason: '用户在评价当前产物；先判断是否修当前阶段或回写上游设定/大纲/Brief。',
    };
  }
  return {
    classification: 'free_text_instruction',
    recommended_action: 'route_by_intent_schema',
    suggested_workflow_type: suggestedWorkflowType(normalized),
    target_scope: targetScope,
    reason: '自由输入需要先做结构化意图识别，再决定是否沿用当前任务。',
  };
}

function inspectProjectTreeSymlinks(projectRoot) {
  const root = path.resolve(projectRoot);
  const symlinks = [];
  try {
    if (fs.lstatSync(root).isSymbolicLink()) return { symlinks: ['.'], error: '' };
    const visit = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const absolute = path.join(dir, entry.name);
        const relative = rel(root, absolute);
        const entryStat = fs.lstatSync(absolute);
        if (entryStat.isSymbolicLink()) {
          symlinks.push(relative);
        } else if (relative === '.git' || relative.startsWith('.git/')) {
          continue;
        } else if (entryStat.isDirectory()) {
          visit(absolute);
        }
      }
    };
    visit(root);
    return { symlinks: symlinks.sort(), error: '' };
  } catch (error) {
    return { symlinks, error: String(error && error.message ? error.message : error) };
  }
}

function acceptedShortPlanningMemoryBoundary(task, result, execution) {
  const stageId = String(result.stage_id || execution.stage_id || task.current_stage || '');
  if (!['project_seed', 'material_card', 'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline', 'feedback_apply_patch'].includes(stageId)) return false;
  const validation = result.memory_validation && typeof result.memory_validation === 'object'
    ? result.memory_validation
    : {};
  if (String(validation.stage_attempt_id || '') !== String(execution.stage_attempt_id || '')) return false;
  const boundary = String(validation.boundary || '');
  const status = String(validation.status || '');
  if (boundary === 'pre_commit' && ['pass', 'not_recorded'].includes(status)) return true;
  if (boundary !== 'accepted_commit_replay' || status !== 'accepted_transaction') return false;
  const resultCommitId = String((((result || {}).chapter_commit || {}).accepted_commit_id) || (((result.evidence || [])[0] || {}).commit_id) || '');
  return Boolean(resultCommitId && resultCommitId === String(validation.accepted_commit_id || ''));
}

function detailOutlineReviewAccepted(result) {
  const quality = (((result || {}).outputs || {}).detail_outline_quality) || {};
  return ['pass', 'pass_with_advisory'].includes(String(quality.status || ''));
}

function detailOutlineTargetKey(target) {
  if (!target || typeof target !== 'object') return '';
  const targetId = String(target.target_id || '');
  if (targetId) return `target_id:${targetId}`;
  const outlinePath = String(target.outline_path || '');
  const outlineSha256 = String(target.outline_sha256 || '');
  return outlinePath && outlineSha256 ? `${outlinePath}\n${outlineSha256}` : '';
}

function longformReviewReturnWaitingProducer(task) {
  return String((task || {}).workflow_type || '') === 'long_write'
    && ['master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief'].includes(String((task || {}).current_stage || ''))
    && String((((task || {}).machine || {}).last_transition) || '') === 'review_failed_return_to_asset';
}

function safeLongPathSegment(value) {
  return String(value || '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'attempt-pending';
}

function suggestedWorkflowType(text) {
  if (/封面|封皮|书皮/.test(text)) return 'cover';
  if (/短篇.*(扫榜|排行|什么火)|((扫榜|排行|什么火).*)短篇/.test(text)) return 'short_scan';
  if (/长篇.*(扫榜|排行|什么火)|((扫榜|排行|什么火).*)长篇|起点|番茄|晋江/.test(text)) return 'long_scan';
  if (/短篇.*(拆文|拆书|拆解|分析)|((拆文|拆书|拆解|分析).*)短篇/.test(text)) return 'short_analyze';
  if (/审阅|审查|复检/.test(text)) return 'review_repair';
  if (/拆文|拆书|拆解|学习/.test(text)) return 'long_analyze';
  if (/短篇|小节|脑洞|素材卡/.test(text)) return 'short_write';
  if (/去\s*AI|AI味|润色|精修/.test(text)) return 'deslop';
  if (/下载|导入|续更/.test(text)) return 'download_import';
  if (/长篇|章节|卷纲|细纲|正文|扩容|缩容/.test(text)) return 'long_write';
  return '';
}

function isStructuralScopeChange(text) {
  if (/扩容|缩容|重排/.test(text)) return true;
  const unit = '(?:第\\s*\\d+\\s*)?(?:卷|章|章节|节|小节)';
  const structuralAction = '(?:插入|插一|增加|新增|拆分|拆成|合并|删除|删掉|前移|后移|移动)';
  return new RegExp(`${structuralAction}[^。；，,]{0,18}${unit}|${unit}[^。；，,]{0,18}${structuralAction}`).test(text);
}

function inferStructureChangeType(text) {
  if (/插入|插章/.test(text)) return 'insert';
  if (/合并/.test(text)) return 'merge';
  if (/删除|删章/.test(text)) return 'delete';
  if (/扩容/.test(text)) return 'expand';
  if (/缩容/.test(text)) return 'shrink';
  if (/前移|后移/.test(text)) return 'move';
  if (/重排/.test(text)) return 'reorder';
  return '';
}

function inferCoverOperation(userGoal, scope) {
  return /覆盖|替换|overwrite/i.test(`${userGoal || ''} ${scope || ''}`) ? 'overwrite' : 'generate';
}

function synchronizeShortUnitScope(task, sectionIndex, stageId) {
  const normalizedIndex = Number(sectionIndex || 0);
  if (!Number.isInteger(normalizedIndex) || normalizedIndex < 1) return;
  const scope = `第${normalizedIndex}节`;
  task.scope = scope;
  task.unit_lifecycle = {
    ...(task.unit_lifecycle || {}),
    unit_type: 'section',
    status: 'active',
    current_scope: scope,
    current_stage: String(stageId || task.current_stage || ''),
    updated_at: new Date().toISOString(),
  };
}

function shortPlanningInputs(stageId) {
  const map = {
    project_seed: [],
    material_card: [],
    short_setting: ['素材卡.md'],
    platform_genre_lock: ['素材卡.md', '设定.md'],
    rhythm_pattern_selection: ['素材卡.md', '设定.md'],
    section_outline: ['素材卡.md', '设定.md'],
  };
  return map[String(stageId || '')] || [];
}

function hasAuthoredQualityEvidence(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  if (String(value.summary || '').trim()) return true;
  const checks = Array.isArray(value.checks) ? value.checks : [];
  if (checks.some((item) => ['status', 'evidence', 'evidence_quote'].some((key) => String((item || {})[key] || '').trim()))) return true;
  const coverage = Array.isArray(value.outline_coverage) ? value.outline_coverage : [];
  if (coverage.some((item) => ['status', 'evidence_quote'].some((key) => String((item || {})[key] || '').trim()))) return true;
  const metadata = value.acceptance_metadata && typeof value.acceptance_metadata === 'object'
    ? value.acceptance_metadata
    : {};
  if ((Array.isArray(metadata.revealed_information) && metadata.revealed_information.length)
    || (metadata.character_state && typeof metadata.character_state === 'object' && Object.keys(metadata.character_state).length)
    || String(metadata.open_hook || '').trim()) return true;
  const reader = value.reader_milestone && typeof value.reader_milestone === 'object'
    ? value.reader_milestone
    : {};
  return Object.values(reader).some((item) => String(item || '').trim());
}

function shortPlanningCanonicalTarget(stageId) {
  return ({
    project_seed: '素材卡.md',
    material_card: '素材卡.md',
    short_setting: '设定.md',
    platform_genre_lock: '设定.md',
    rhythm_pattern_selection: '设定.md',
    section_outline: '小节大纲.md',
  })[String(stageId || '')] || '';
}

function markShortMemoryMigrationRefreshed(task, context, targetStage) {
  if (String((((task || {}).memory_migration || {}).status) || '') !== 'refresh_on_resume') return;
  if (!context || context.blocking || String(context.status || '') !== 'assembled') return;
  task.memory_migration = {
    ...(task.memory_migration || {}),
    status: 'completed',
    refreshed_stage: String(targetStage || ''),
    refreshed_packet: String(context.packet_json || ''),
    refreshed_revision: String((((context || {}).memory_contract || {}).memory_revision) || ''),
    refreshed_at: new Date().toISOString(),
  };
}

function preservePreviousStageAttempt(task, nextWorkUnitId, preservedAt) {
  const previous = task && task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : null;
  const history = Array.isArray((task || {}).stage_attempt_history)
    ? task.stage_attempt_history.slice()
    : [];
  if (previous && previous.stage_attempt_id
    && !history.some(item => String((item || {}).stage_attempt_id || '') === String(previous.stage_attempt_id))) {
    history.push({
      stage_attempt_id: String(previous.stage_attempt_id || ''),
      work_unit_id: String(previous.work_unit_id || ''),
      stage_id: String(previous.stage_id || ''),
      status: String(previous.status || ''),
      expected_result_packet: String(previous.expected_result_packet || ''),
      accepted_result_packet: String(previous.accepted_result_packet || previous.result_packet || ''),
      failed_result_packet: String(previous.failed_result_packet || ''),
      started_at: String(previous.started_at || ''),
      preserved_at: String(preservedAt || new Date().toISOString()),
    });
  }
  task.stage_attempt_history = history.slice(-100);
  const sameUnitAttempts = task.stage_attempt_history
    .filter(item => String((item || {}).work_unit_id || '') === String(nextWorkUnitId || ''));
  const latest = sameUnitAttempts[sameUnitAttempts.length - 1] || null;
  return {
    attempt_no: sameUnitAttempts.length + 1,
    supersedes_attempt_id: latest ? String(latest.stage_attempt_id || '') : '',
  };
}

function runningStageDisplayName(stageId) {
  const names = {
    feedback_impact_sync: '分析反馈影响',
    feedback_apply_patch: '回写已确认的设定与小节大纲',
    section_plan_lock: '确认总节数与小节标题',
    section_brief_ready: '生成当前小节写作提要',
    section_draft_loop: '写作当前小节',
    section_repair_loop: '修订当前小节',
    final_check: '完成全篇最终检查',
  };
  return names[String(stageId || '')] || '继续当前任务';
}

function runningStageExecutionBlocker(execution) {
  const memory = execution && execution.memory_context;
  if (memory && memory.blocking === true) {
    return { reason: String(memory.reason || memory.status || '当前阶段记忆上下文不可用。') };
  }
  for (const field of ['character_contract_blocking', 'context_packet_blocking']) {
    const finding = execution && execution[field];
    if (!finding || typeof finding !== 'object') continue;
    if (finding.blocking === true || String(finding.status || '').startsWith('blocked_')) {
      return { reason: String(finding.reason || finding.status || '当前阶段上下文存在阻断项。') };
    }
  }
  return null;
}

function shortFeedbackExecutionContractCurrent(task, execution) {
  if (String((task || {}).current_stage || '') !== 'feedback_impact_sync') return true;
  const expected = String((execution || {}).expected_result_packet || '');
  const writeSet = Array.isArray((execution || {}).write_set) ? execution.write_set.map(String) : [];
  const completion = String((execution || {}).stage_completion_command || (execution || {}).execution_command || '');
  return Boolean(expected
    && writeSet.length === 1
    && writeSet[0] === expected
    && /workflow-state-machine\.js apply-result/u.test(completion)
    && completion.includes(`--result ${JSON.stringify(expected)}`));
}

function bindStageCompletionContract(execution) {
  if (!execution || typeof execution !== 'object') return execution;
  const completionCommand = String(execution.stage_completion_command || execution.execution_command || '');
  if (!completionCommand) return execution;
  return {
    ...execution,
    stage_completion_command: completionCommand,
    current_required_action: 'edit_write_set',
    after_write_action: {
      type: 'execute_command',
      command: completionCommand,
    },
    completion_required_before_reply: true,
    stage_completion_contract: 'read_context_edit_write_set_execute_completion_command_consume_result_same_turn',
    execution_sequence: ['read_context', 'edit_write_set', 'execute_completion_command', 'consume_result_presentation'],
  };
}

function awaitingCurrentShortFeedbackProposal(task) {
  const pendingFeedbackId = String((((task || {}).pending_feedback || {}).feedback_id) || '');
  const proposal = task && task.proposed_plan && typeof task.proposed_plan === 'object' ? task.proposed_plan : {};
  return Boolean(pendingFeedbackId)
    && String(proposal.feedback_id || '') === pendingFeedbackId
    && String(proposal.status || '') === 'awaiting_user_confirmation';
}

function visibleChoiceBinding(task, pending, root) {
  return {
    pending_action_id: String((pending || {}).id || ''),
    visible_choice_hash: String((pending || {}).visible_choice_hash || ''),
    state_version: Number(task.state_version || 0),
    book_root: root,
  };
}

function isExpressionOnlyShortFeedback(text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (/(扩容|缩容|增加.{0,4}(节|情节)|删除.{0,4}(节|情节)|合并.{0,4}(节|情节)|重排|改大纲|改设定|人物动机|核心反转|主线|结局)/u.test(value)) return false;
  return /(AI\s*味|ai\s*味|破折号|省略号|标点|句式|用词|措辞|语气|口吻|对白.{0,4}(自然|生硬)|短句.{0,4}(太多|过密)|复读|重复表达)/u.test(value);
}

function pendingFeedbackSectionIndex(pending) {
  const explicit = Number((pending || {}).section_index || 0);
  if (Number.isInteger(explicit) && explicit > 0) return explicit;
  const match = `${String((pending || {}).scope_snapshot || '')}\n${String((pending || {}).text || '')}`.match(/第\s*0*(\d+)\s*节/u);
  return match ? Number(match[1]) : 0;
}

function shortBriefPath(sectionIndex) {
  return `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
}

function invalidateShortFeedbackAnalysis(task, now = new Date().toISOString()) {
  task.short_feedback_impact = null;
  if (task.feedback_revision_queue) {
    const queue = task.feedback_revision_queue;
    task.feedback_revision_history = [
      ...(Array.isArray(task.feedback_revision_history) ? task.feedback_revision_history : []),
      {
        queue_id: String(queue.queue_id || ''),
        feedback_id: String(queue.feedback_id || ''),
        current_section_index: Number(queue.current_section_index || 0) || null,
        completed_sections: Array.isArray(queue.completed_sections) ? queue.completed_sections : [],
        remaining_sections: (Array.isArray(queue.items) ? queue.items : [])
          .filter(item => String((item || {}).status || '') !== 'accepted')
          .map(item => Number((item || {}).section_index || 0))
          .filter(Boolean),
        snapshot_at: now,
        reason: 'new_feedback_received',
      },
    ].slice(-20);
    queue.interruption = {
      status: 'feedback_analysis_pending',
      section_index: Number(queue.current_section_index || 0) || null,
      at: now,
    };
    queue.checkpoints = [
      ...(Array.isArray(queue.checkpoints) ? queue.checkpoints : []),
      {
        event: 'feedback_received',
        section_index: Number(queue.current_section_index || 0) || null,
        at: now,
      },
    ].slice(-50);
    queue.updated_at = now;
  }
  task.last_selection = null;
  task.machine = task.machine || {};
  task.machine.completed_stages = (Array.isArray(task.machine.completed_stages) ? task.machine.completed_stages : [])
    .filter(stageId => !['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || '')));
  task.machine.remaining_stages = [
    'feedback_impact_sync',
    'feedback_apply_patch',
    ...(Array.isArray(task.machine.remaining_stages) ? task.machine.remaining_stages : [])
      .filter(stageId => !['feedback_impact_sync', 'feedback_apply_patch'].includes(String(stageId || ''))),
  ];
  task.machine.last_result_packet = '';
  task.machine.last_transition = 'short_feedback_reanalysis_required';
  const latest = String(((((task || {}).runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '');
  if (/\/feedback_(?:impact_sync|apply_patch)(?:\.|\.result)/.test(latest)) {
    task.runtime_guard.heartbeat.latest_trusted_artifact = '';
  }
}

function isTrustedShortResumePacket(packet, task, stageId, sectionIndex) {
  if (!packet || packet.__error) return false;
  if (String(packet.workflow_id || '') && String(packet.workflow_id) !== String(task.workflow_id || '')) return false;
  if (String(packet.stage_id || '') !== stageId) return false;
  if (Number(packet.current_section_index || 0) !== Number(sectionIndex)) return false;
  if (Array.isArray(packet.blocking_findings) && packet.blocking_findings.length > 0) return false;
  const verdicts = [packet.verification_result, packet.output_health_result, packet.machine_gate_result, packet.quality_gate_result, packet.story_value_result];
  return verdicts.some((value) => /^(pass|passed|accepted|approved|ok)$/i.test(String(value || '')));
}

function cardCommandResult(status, cards, number) {
  const card = cards.find(item => Number(item.display_no) === number);
  return card ? { status, card, number } : { status: 'invalid', number, available: cards.length };
}

function infoSourcePrimaryRoute(card) {
  const route = (Array.isArray((card || {}).route_fit) ? card.route_fit : [])[0];
  if (typeof route === 'string') return route;
  return String((route || {}).route_name || '待补充');
}

function infoSourceMaterialScore(card) {
  const scorecard = card && card.scorecard && typeof card.scorecard === 'object' ? card.scorecard : {};
  const value = Number((card || {}).material_score || scorecard.material_score || 0);
  return Number.isFinite(value) ? value : 0;
}

function orderedStage(tpl, stageId) {
  return Boolean(tpl && Array.isArray(tpl.stages) && tpl.stages.some((item) => String((item || {}).stage_id || '') === stageId));
}

function buildShortFeedbackProposal(task, result, now = new Date().toISOString()) {
  const pending = task.pending_feedback || {};
  const feedbackId = String(result.feedback_id || pending.feedback_id || '');
  const proposed = result.proposed_plan && typeof result.proposed_plan === 'object' && !Array.isArray(result.proposed_plan)
    ? result.proposed_plan
    : {};
  const items = Array.isArray(pending.items) && pending.items.length
    ? pending.items
    : String(pending.text || '').trim() ? [{ feedback_id: feedbackId, text: String(pending.text || '').trim(), impact_level_hint: String(result.impact_level || '') }] : [];
  const requirements = Array.isArray(proposed.requirements) && proposed.requirements.length
    ? proposed.requirements.map((item, index) => ({
      requirement_id: String((item || {}).requirement_id || `${feedbackId}.requirement-${index + 1}`),
      text: String((item || {}).text || (item || {}).content || '').trim(),
      impact_level: String((item || {}).impact_level || result.impact_level || ''),
    })).filter(item => item.text)
    : items.map(item => ({
      requirement_id: String(item.feedback_id || ''),
      text: String(item.text || '').trim(),
      impact_level: String(item.impact_level_hint || result.impact_level || ''),
    }));
  return {
    schema_version: '1.0.0',
    proposal_id: String(proposed.proposal_id || `proposal.${feedbackId || 'unbound'}`),
    status: 'awaiting_user_confirmation',
    feedback_id: feedbackId,
    summary: String(proposed.summary || result.plan_summary || pending.text || '').trim(),
    execution_summary: String(proposed.execution_summary || result.handoff_summary || result.next_recommendation || ''),
    requirements,
    impact_level: String(result.impact_level || ''),
    affected_sections: Array.isArray(result.affected_sections) ? result.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(result.affected_assets) ? result.affected_assets : [],
    downstream_impact: result.downstream_impact && typeof result.downstream_impact === 'object' ? result.downstream_impact : {},
    revision_groups: Array.isArray(result.revision_groups) ? result.revision_groups : [],
    result_packet_path: String(result.result_packet_path || ''),
    proposed_at: now,
  };
}

function shortFeedbackImpactFromPacket(packet, packetPath) {
  return {
    status: 'ok',
    feedback_id: String(packet.feedback_id || ''),
    impact_level: String(packet.impact_level || ''),
    affected_sections: Array.isArray(packet.affected_sections) ? packet.affected_sections.map(Number).filter(Number.isInteger) : [],
    affected_assets: Array.isArray(packet.affected_assets) ? packet.affected_assets : [],
    downstream_impact: packet.downstream_impact && typeof packet.downstream_impact === 'object' ? packet.downstream_impact : {},
    revision_groups: Array.isArray(packet.revision_groups) ? packet.revision_groups : [],
    next_stage_id: 'feedback_apply_patch',
    result_packet_path: String(packetPath || ''),
    analyzed_at: String(packet.completed_at || packet.updated_at || ''),
    recovered_from_result_packet: true,
  };
}

function targetRevalidationSnapshotNeedsRefresh(task) {
  return String((task || {}).workflow_type || '') === 'long_write'
    && String((task || {}).current_stage || '') === 'detail_outline_review'
    && String((((task || {}).longform_target_revalidation || {}).status) || '') === 'running'
    && String((((task || {}).stage_execution || {}).stage_id) || '') === 'detail_outline_review'
    && !String((((task || {}).longform_target_revalidation || {}).write_snapshot_refreshed_at) || '');
}

function detailOutlineIdentity(target) {
  return {
    outline_path: String((target || {}).outline_path || '').replace(/\\/g, '/'),
    outline_sha256: String((target || {}).outline_sha256 || '').toLowerCase(),
  };
}

function omitVisibleResponse(value) {
  if (!value || typeof value !== 'object') return value;
  const { visible_response: _visibleResponse, ...rest } = value;
  return rest;
}

function buildWorkflowRegistrySnapshot(tpl, primaryOwner) {
  const overlay = (tpl && tpl.private_overlay) || null;
  const ownerModule = String((overlay || {}).module || (primaryOwner || {}).owner_module || '');
  if (!overlay) {
    return {
      profile: 'public',
      owner_module: ownerModule,
      registry_id: 'public',
      registry_digest: '',
    };
  }
  return {
    profile: 'private',
    owner_module: ownerModule,
    // registry_id 用 module 名, 稳定且对合理内容更新不敏感.
    // digest 仅记录来源路径指纹, 不参与强校验, 避免微调阻断.
    registry_id: ownerModule || 'private',
    registry_digest: String(overlay.source || ''),
  };
}

function rebindTaskToCurrentProjectRoot(task) {
  if (!task || typeof task !== 'object') return false;
  let changed = false;
  const setPortable = (holder, key) => {
    if (holder && holder[key] !== '.') {
      holder[key] = '.';
      changed = true;
    }
  };
  setPortable(task, 'book_root');
  setPortable(((task.runtime_guard || {}).checkpoint_policy), 'project_root');
  setPortable(task.pending_action, 'book_root');
  setPortable(task.last_selection, 'book_root');
  return changed;
}

function renderRpdMarkdown(task, tpl) {
  const stages = tpl && Array.isArray(tpl.stages) ? tpl.stages.map((stageDef) => stageDef.stage_id).join(' -> ') : '';
  return [
    '# 任务需求与读者承诺文档',
    '',
    `- 任务编号：${task.workflow_id}`,
    `- 任务类型：${task.workflow_type}`,
    `- 用户目标：${task.user_goal || ''}`,
    `- 任务范围：${task.scope || '未限定'}`,
    `- 推进策略：${task.completion_policy}`,
    '',
    '## 读者承诺',
    '',
    '本任务必须服务当前作品的读者体验：情节可信、人物连续、钩子可追、情绪兑现，不用机械执行替代故事判断。',
    '',
    '## 任务边界',
    '',
    '- 不凭聊天记忆推进任务。',
    '- 不把阶段完成伪装成整个流程完成。',
    '- 不绕过机器门、故事质量门和状态交接。',
    '- 需要改变上游设定、大纲、细纲、素材卡或章节结构时，先回到计划/Brief 阶段。',
    '',
    '## 验收标准',
    '',
    '- 当前阶段的 result packet 与任务状态一致。',
    '- 任务事实只以任务目录 `task.json` 为准；`current-task.json` 只记录界面焦点。',
    '- 所有写入动作都有最后可信产物或验证证据。',
    '- 完成后给出下一步候选或明确收束。',
    '',
    '## 阶段序列',
    '',
    stages || '未加载模板阶段。',
    '',
  ].join('\n');
}

function latestArchivedRepairCandidate(root, taskDirectory) {
  const artifactsDir = path.join(taskDirectory, 'artifacts');
  if (!fs.existsSync(artifactsDir)) return '';
  const names = fs.readdirSync(artifactsDir)
    .filter(name => /^staged_repair_candidate\.archived-[A-Za-z0-9_-]+$/.test(name))
    .sort();
  if (!names.length) return '';
  const candidate = resolveSafeProjectFile(root, path.join(artifactsDir, names.at(-1)));
  return candidate && fs.existsSync(candidate) ? rel(root, candidate) : '';
}

function parseInfoSourceCardSelection(root, task, input) {
  const cards = infoSourceSelectionCards(root, task);
  if (!cards.length) return { status: 'not_applicable', cards: [] };
  const text = String(input || '').trim();
  if (!text || /^(?:看|查看|详情|保存退出|保存并退出|暂停|稍后再选)$/u.test(text)) return { status: 'not_selected', cards: [] };
  const explicit = /^\d+(?:\s*(?:[+、，,]|和|及|与|\s)\s*\d+)*$/u.test(text);
  const natural = /(?:选|选择|倾向|喜欢|采用|要|用|资讯|素材|第\s*\d+\s*张)/u.test(text);
  if (!explicit && !natural) return { status: 'not_selected', cards: [] };
  const numbers = [...text.matchAll(/(\d+)/gu)].map(match => Number(match[1])).filter(number => Number.isInteger(number) && number > 0);
  const unique = [...new Set(numbers)];
  if (!unique.length) return { status: 'not_selected', cards: [] };
  const selected = unique.map(number => cards.find(card => card.display_no === number)).filter(Boolean);
  if (selected.length !== unique.length) return { status: 'invalid', cards: [], requested: unique, available: cards.length };
  return { status: 'selected', cards: selected };
}

function parseInfoSourceCardCommand(root, task, input) {
  const text = String(input || '').trim();
  if (!text) return { status: 'not_applicable' };
  if (/^(?:保存退出|保存并退出|暂停|稍后再选)$/u.test(text)) return { status: 'pause' };
  const cards = infoSourceSelectionCards(root, task);
  if (!cards.length) return { status: 'not_applicable' };
  const detail = text.match(/^(?:看|查看)\s*(?:第\s*)?(\d+)\s*(?:张|个)?(?:详情|卡片|资讯|素材)?$/u);
  return detail ? cardCommandResult('inspect', cards, Number(detail[1])) : { status: 'not_applicable' };
}

function stageWorkUnitId(task, stageId, scope) {
  const identity = [
    String((task || {}).workflow_id || 'workflow'),
    String(stageId || 'stage'),
    String(scope || 'current-scope'),
  ].join('|');
  return `wu-${crypto.createHash('sha256').update(identity).digest('hex').slice(0, 16)}`;
}

function failClosedPlanningRevision(execution, reason) {
  if (execution && typeof execution === 'object') {
    execution.write_set = [];
    execution.canonical_write_set = [];
    execution.revision_targets = [];
    execution.planning_targets = [];
    delete execution.execution_command;
    execution.context_packet_warning = reason;
  }
  return { status: 'blocked', reason };
}

function longPlanningStagedPath(task, execution, index, canonical) {
  const attempt = safeLongPathSegment(String((execution || {}).stage_attempt_id || 'attempt'));
  const workspaceId = crypto.createHash('sha256')
    .update(`${String((task || {}).workflow_id || '')}\0${String((execution || {}).stage_id || 'long-planning')}\0${attempt}`)
    .digest('hex')
    .slice(0, 12);
  const basename = path.posix.basename(String(canonical || ''));
  return `追踪/workflow/staging/${workspaceId}/${String(index + 1).padStart(3, '0')}-${basename}`;
}

function longformReviewReturnIntro(task) {
  if (!longformReviewReturnWaitingProducer(task)) return '';
  const messages = arrayOrEmpty((((task || {}).machine || {}).last_blocking_findings))
    .map((finding) => String((finding || {}).message || finding || '').trim())
    .filter(Boolean)
    .slice(0, 3);
  return messages.length > 0
    ? `上一轮审阅未通过：${messages.join('；')}`
    : '上一轮审阅未通过，已返回当前规划资产修订。';
}

function stageCanonicalWriteSet(result) {
  const candidates = [
    ...arrayOrEmpty((result || {}).result_write_set),
    ...arrayOrEmpty((result || {}).changed_assets),
    ...arrayOrEmpty((result || {}).changed_files),
    ...arrayOrEmpty((result || {}).created_files),
  ];
  return Array.from(new Set(candidates.map(item => String(item || '').trim()).filter(Boolean)));
}

function pendingDetailOutlineTargets(task) {
  const consumed = new Set(arrayOrEmpty((task || {}).consumed_detail_outline_targets)
    .map(detailOutlineTargetKey)
    .filter(Boolean));
  return arrayOrEmpty((task || {}).accepted_detail_outline_targets)
    .filter((target) => {
      const key = detailOutlineTargetKey(target);
      return key && !consumed.has(key);
    });
}

function normalizedVolumeIdentity(value) {
  const raw = String(value || '').replace(/\s+/g, '');
  const match = raw.match(/^第([0-9一二三四五六七八九十百]+)卷$/)
    || raw.match(/^卷([0-9一二三四五六七八九十百]+)$/)
    || raw.match(/^([0-9一二三四五六七八九十百]+)$/);
  if (!match) return '';
  if (/^\d+$/.test(match[1])) return String(Number(match[1]));
  const number = chineseNumeralValue(match[1]);
  return number > 0 ? String(number) : '';
}

function workflowDir(root) {
  return path.join(root, '追踪', 'workflow');
}

function durableTaskSnapshotPath(taskOrWorkflowId) {
  if (taskOrWorkflowId && typeof taskOrWorkflowId === 'object' && taskOrWorkflowId.task_dir) {
    return `${String(taskOrWorkflowId.task_dir).replace(/\\\\/g, '/').replace(/\/$/, '')}/task.json`;
  }
  return `追踪/workflow/tasks/${String(taskOrWorkflowId || 'unknown-workflow')}/task.json`;
}

function resolveProjectRootReference(reference, root) {
  const value = String(reference || '.').trim();
  if (!value || value === '.') return path.resolve(root);
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
}

function sameDetailOutlineIdentities(actual, expected) {
  const normalized = (items) => arrayOrEmpty(items).map(detailOutlineIdentity);
  return sameContractValue(normalized(actual), normalized(expected));
}

function infoSourceRecommendationLabel(card) {
  const score = infoSourceMaterialScore(card);
  if (String((card || {}).verdict || '') === 'write' && score >= 8) return '推荐';
  if (score >= 6.5) return '可组合';
  return '备选';
}

function shortFeedbackId(text, receivedAt) {
  return `feedback-${crypto.createHash('sha256').update(`${String(receivedAt || '')}\n${String(text || '').trim()}`, 'utf8').digest('hex').slice(0, 16)}`;
}

function shortPlanningWorkspacePath(task, targetStage, attempt, canonical) {
  const workspaceId = crypto.createHash('sha256')
    .update(`${String(task.workflow_id || '')}\0${String(targetStage || '')}\0${String(attempt || '')}`)
    .digest('hex')
    .slice(0, 12);
  return `追踪/workflow/staging/${workspaceId}/${path.basename(canonical)}`;
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function normalizeWriteSetPath(value) {
  const raw = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//, '');
  if (!raw || path.isAbsolute(raw) || raw.split('/').includes('..')) return '';
  return raw.replace(/\/{2,}/g, '/');
}

function resolveInsideProject(projectRoot, relativePath) {
  const root = path.resolve(projectRoot);
  const file = path.resolve(root, relativePath);
  if (file === root || !file.startsWith(`${root}${path.sep}`)) return '';
  return file;
}

module.exports = {
  readText,
  rel,
  positiveContextChars,
  hasActiveWorkflowStatus,
  createStageAttemptId,
  arrayOrEmpty,
  normalizeContentHash,
  sameContractValue,
  chineseNumeralValue,
  normalizedChapterIdentity,
  isConsoleErrorStatus,
  renderRpdMarkdown,
  rebindTaskToCurrentProjectRoot,
  buildWorkflowRegistrySnapshot,
  omitVisibleResponse,
  detailOutlineIdentity,
  targetRevalidationSnapshotNeedsRefresh,
  shortFeedbackImpactFromPacket,
  buildShortFeedbackProposal,
  orderedStage,
  infoSourceMaterialScore,
  infoSourcePrimaryRoute,
  cardCommandResult,
  isTrustedShortResumePacket,
  invalidateShortFeedbackAnalysis,
  shortBriefPath,
  pendingFeedbackSectionIndex,
  isExpressionOnlyShortFeedback,
  visibleChoiceBinding,
  awaitingCurrentShortFeedbackProposal,
  bindStageCompletionContract,
  shortFeedbackExecutionContractCurrent,
  runningStageExecutionBlocker,
  runningStageDisplayName,
  preservePreviousStageAttempt,
  markShortMemoryMigrationRefreshed,
  shortPlanningCanonicalTarget,
  hasAuthoredQualityEvidence,
  shortPlanningInputs,
  synchronizeShortUnitScope,
  inferCoverOperation,
  inferStructureChangeType,
  isStructuralScopeChange,
  suggestedWorkflowType,
  safeLongPathSegment,
  longformReviewReturnWaitingProducer,
  detailOutlineTargetKey,
  detailOutlineReviewAccepted,
  acceptedShortPlanningMemoryBoundary,
  normalizeLifecycle,
  buildConfirmationContext,
  resolveSafeProjectFile,
  readJsonlRecords,
  infoSourceSelectionCards,
  reopenShortTaskForFeedback,
  shortSettingCandidateView,
  synchronizeShortWholeStoryScope,
  inferFreeTextClassification,
  inspectProjectTreeSymlinks,
  latestArchivedRepairCandidate,
  parseInfoSourceCardSelection,
  parseInfoSourceCardCommand,
  stageWorkUnitId,
  failClosedPlanningRevision,
  longPlanningStagedPath,
  longformReviewReturnIntro,
  stageCanonicalWriteSet,
  pendingDetailOutlineTargets,
  normalizedVolumeIdentity,
  workflowDir,
  durableTaskSnapshotPath,
  resolveProjectRootReference,
  sameDetailOutlineIdentities,
  infoSourceRecommendationLabel,
  shortFeedbackId,
  shortPlanningWorkspacePath,
  hashFile,
  normalizeWriteSetPath,
  resolveInsideProject,
};
