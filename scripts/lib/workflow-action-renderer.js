'use strict';

const crypto = require('crypto');
const { resolveReviewTarget } = require('./review-target-policy');

const VISIBLE_STAGE_LABELS = {
  range_lock: '锁定审阅范围', evidence_scan: '扫描审阅证据', classify_findings: '归类审阅发现', repair_plan: '生成修复计划',
  user_scope_choice: '确认修复范围', repair_execution_plan: '生成修复执行方案', staged_repair_candidate: '准备修复草稿',
  repair_machine_gate: '检查修复草稿', execute_repair: '执行已确认修复方案', recheck: '复检修复结果', closure: '生成审阅总报告',
  material_card: '确认素材卡', short_setting: '确认短篇设定', section_outline: '确认小节大纲', section_plan_lock: '确认总节数与小节标题', section_brief: '生成当前小节写作说明',
  draft_section: '写当前小节正文', section_machine_gate: '检查当前小节', section_repair_loop: '修复当前小节',
  prose: '写当前章节正文', chapter_machine_gate: '检查当前章节', drift_gate: '检查剧情连续性', handoff: '保存章节交接',
};
function buildReviewBatchReacceptancePendingAction(task, batch) {
  const range = String(batch.range || '');
  return decoratePendingAction({
    id: `pa-reaccept-evidence-scan-batch-${batch.id}`,
    question: `旧批次需重新验收（从 ${range} 开始）`,
    options: [
      {
        number: 1,
        action_id: 'continue_next_stage',
        label: `重新验收 ${range}`,
        target_stage: 'evidence_scan',
        target_scope: range,
        risk_level: 'medium',
        requires_user_confirm: false,
        execution_mode: 'continue_current_stage',
        completion_boundary: 'batch_completed',
      },
      { number: 2, action_id: 'pause', label: '停止并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
}

function normalizeSelectedAction(option, selectedNumber, selectedAt, pending) {
  const maxUnits = option.max_units !== undefined ? Number(option.max_units) : null;
  return {
    selected_at: selectedAt,
    selected_number: selectedNumber,
    action_id: String(option.action_id || option.action || ''),
    label: String(option.label || ''),
    description: String(option.description || ''),
    target_stage: String(option.target_stage || ''),
    target_scope: option.target_scope || option.scope ? String(option.target_scope || option.scope) : '',
    target_files: Array.isArray(option.target_files) ? option.target_files.slice() : [],
    risk_level: String(option.risk_level || 'medium'),
    requires_user_confirm: Boolean(option.requires_user_confirm),
    selection_id: String((pending || {}).id || ''),
    pending_action_id: String((pending || {}).id || ''),
    selection_expires_at: String((pending || {}).expires_at || ''),
    visible_choice_hash: String((pending || {}).visible_choice_hash || ''),
    state_version: Number((pending || {}).state_version || 0),
    book_root: String((pending || {}).book_root || ''),
    execution_contract: {
      mode: String(option.execution_mode || option.mode || 'exact_selected_option'),
      max_units: Number.isFinite(maxUnits) ? maxUnits : null,
      stop_after: option.stop_after ? String(option.stop_after) : '',
      completion_boundary: option.completion_boundary ? String(option.completion_boundary) : '',
      forbidden_interpretations: Array.isArray(option.forbidden_interpretations) ? option.forbidden_interpretations.slice() : [],
    },
  };
}

function buildReviewBatchPendingAction(task, batch, reviewPlan) {
  const target = task.review_target || resolveReviewTarget({ text: task.user_goal, scope: task.scope }, {});
  const completed = Number(((task.review_batches || {}).completed_count) || 0);
  const total = Math.max(1, Number(((task.review_batches || {}).total_count) || 1));
  const progress = Math.min(100, Math.floor((completed / total) * 100));
  const progressLabel = progress > 0 ? `（已完成 ${progress}%）` : '';
  return decoratePendingAction({
    id: `pa-review-progress-${task.workflow_id}`,
    question: target.visible_label,
    options: [
      {
        number: 1,
        action_id: 'continue_next_stage',
        label: `继续${target.visible_label}${progressLabel}`,
        target_stage: 'evidence_scan',
        target_scope: target.narrative_scope,
        risk_level: 'medium',
        requires_user_confirm: false,
        execution_mode: 'continue_current_stage',
        completion_boundary: 'evidence_checkpoint_completed',
      },
      { number: 2, action_id: 'pause', label: '停止并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
}

function buildPendingAction(tpl, stageDef) {
  if (!stageDef) return { id: 'pa-none', question: '没有可继续阶段', options: [], free_text_enabled: true };
  return decoratePendingAction({
    id: `pa-${stageDef.stage_id}`,
    question: '请选择下一步',
    options: [
      {
        number: 1,
        action_id: 'continue_next_stage',
        label: `继续${visibleStageLabel(stageDef)}`,
        description: stageDef.description || '',
        frontend_surface: stageDef.frontend_surface || '',
        target_stage: stageDef.stage_id,
        risk_level: stageDef.risk_level,
        requires_user_confirm: stageDef.requires_user_confirm,
        execution_mode: 'exact_selected_option',
        completion_boundary: stageDef.requires_user_confirm ? 'stop_after_stage' : 'stage_completed',
      },
      {
        number: 2,
        action_id: 'pause',
        label: '停止并保存断点',
        risk_level: 'low',
        requires_user_confirm: false,
      },
    ],
    free_text_enabled: true,
  });
}

function buildShortSettingCandidatePendingAction(task = {}) {
  const candidate = task.short_setting_candidate && typeof task.short_setting_candidate === 'object'
    ? task.short_setting_candidate
    : {};
  const migrated = candidate.migrated_from_unconfirmed_canonical === true;
  return decoratePendingAction({
    id: `pa-short-setting-candidate-${String(task.workflow_id || 'short')}-${String(candidate.revision || 1)}`,
    question: '请确认人物与剧情设定候选',
    options: [
      {
        action_id: 'accept_short_setting_candidate',
        label: migrated ? '确认当前人物与剧情设定' : '确认当前人物与剧情设定（推荐）',
        description: '确认后才扩写并受控写入设定.md；后续平台、节奏和小节大纲只能引用这个版本。',
        target_stage: 'short_setting',
        risk_level: 'medium',
        requires_user_confirm: true,
        recommended: !migrated,
        execution_mode: 'accept_staged_setting_candidate',
        completion_boundary: 'stop_after_stage',
      },
      {
        action_id: 'inspect_short_setting_candidate',
        label: migrated ? '查看旧版设定候选与依据（推荐）' : '查看设定候选与依据',
        risk_level: 'low',
        requires_user_confirm: false,
        recommended: migrated,
      },
      {
        action_id: 'request_short_setting_revision_input',
        label: '调整人物、关系或剧情方向',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        action_id: 'pause',
        label: '暂停并保存断点',
        risk_level: 'low',
        requires_user_confirm: false,
      },
    ],
    free_text_enabled: true,
    compact_options: true,
  });
}

function buildShortDraftPendingAction(stageDef, task) {
  const match = String((task || {}).scope || '').match(/第\s*0*(\d+)\s*节/u);
  const sectionIndex = match ? Number(match[1]) : 0;
  const sectionLabel = sectionIndex ? `第 ${sectionIndex} 节` : '当前小节';
  const revisionItem = currentRevisionItem(task, sectionIndex);
  const recheckExisting = Boolean(revisionItem && String(revisionItem.prose_status || '') === 'pending_recheck');
  return decoratePendingAction({
    id: `pa-${String((stageDef || {}).stage_id || 'draft_section')}`,
    question: recheckExisting
      ? `${sectionLabel}已有正文，当前进入复检与局部回炉`
      : `${sectionLabel}写作提要已通过，推荐下一步`,
    options: [
      {
        number: 1,
        action_id: recheckExisting ? 'recheck_existing_section' : 'continue_next_stage',
        label: recheckExisting ? `复检并局部回炉${sectionLabel}现有正文（推荐）` : `开始写${sectionLabel}正文（推荐）`,
        description: recheckExisting
          ? `保留符合新规划的现有内容，只修偏离项；通过机器检查和故事质量判断后重新采用。`
          : `只写${sectionLabel}，写完自动进入机器检查；通过后再做一次故事质量判断。`,
        frontend_surface: String((stageDef || {}).frontend_surface || 'short_draft_editor'),
        target_stage: recheckExisting ? 'section_machine_gate' : String((stageDef || {}).stage_id || 'draft_section'),
        risk_level: String((stageDef || {}).risk_level || 'high'),
        requires_user_confirm: true,
        execution_mode: recheckExisting ? 'recheck_existing_then_repair_if_needed' : 'exact_selected_option',
        completion_boundary: recheckExisting ? 'section_reaccepted' : 'stop_after_stage',
      },
      {
        number: 2,
        action_id: 'request_revision_input',
        label: `修改${sectionLabel}；完成后继续后续任务`,
        risk_level: 'low',
        requires_user_confirm: false,
      },
      { number: 3, action_id: 'inspect_current_state', label: '查看本轮修订队列与依据', frontend_surface: 'workflow_queue_detail', risk_level: 'low', requires_user_confirm: false },
      { number: 4, action_id: 'pause', label: '暂停并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
}

function currentRevisionItem(task, sectionIndex) {
  const queue = task && task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (!queue || String(queue.status || '') !== 'running') return null;
  const current = Number(sectionIndex || queue.current_section_index || 0);
  return (Array.isArray(queue.items) ? queue.items : [])
    .find(item => Number((item || {}).section_index || 0) === current) || null;
}

function buildShortRevisionQueueProgress(task = {}, sectionTitles = []) {
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (!queue || String(queue.status || '') !== 'running') return null;
  const items = (Array.isArray(queue.items) ? queue.items : [])
    .filter(item => Number.isInteger(Number((item || {}).section_index)) && Number(item.section_index) > 0)
    .sort((left, right) => Number(left.section_index) - Number(right.section_index));
  if (!items.length) return null;
  const titleMap = new Map((Array.isArray(sectionTitles) ? sectionTitles : [])
    .map(item => [Number((item || {}).section_index || 0), String((item || {}).title || '').trim()]));
  const completed = items.filter(item => String(item.status || '') === 'accepted').length;
  const currentSection = Number(queue.current_section_index || 0);
  const remaining = items.length - completed;
  const visibleItems = items.length <= 12
    ? items
    : items.filter(item => String(item.status || '') !== 'accepted').slice(0, 8);
  const rows = visibleItems.map(item => {
    const sectionIndex = Number(item.section_index);
    const isCompleted = String(item.status || '') === 'accepted';
    const isCurrent = sectionIndex === currentSection && !isCompleted;
    const currentStep = isCurrent && String(item.prose_status || '') === 'pending_recheck'
      && ['draft_first_section', 'draft_section', 'draft_next_section'].includes(String(task.current_stage || ''))
      ? '写作提要已通过，待复检现有正文'
      : currentShortRevisionStep(task);
    return {
      section_index: sectionIndex,
      title: titleMap.get(sectionIndex) || '',
      status: isCompleted ? 'completed' : isCurrent ? 'current' : 'pending',
      status_label: isCompleted ? '已完成' : isCurrent ? currentStep : '待回炉',
      brief_status: String(item.brief_status || ''),
      prose_status: String(item.prose_status || ''),
      accepted_commit_id: String(item.accepted_commit_id || ''),
      completed_at: String(item.completed_at || ''),
      checkpoint: isCompleted
        ? `已采用${item.accepted_commit_id ? `（${String(item.accepted_commit_id).slice(0, 12)}）` : ''}`
        : isCurrent ? currentStep : '等待前序小节完成',
    };
  });
  const groups = revisionQueueGroups(queue, items).map((group, index) => {
    const sections = group.section_indices;
    const completedCount = sections.filter(sectionIndex => {
      const item = items.find(candidate => Number(candidate.section_index) === sectionIndex);
      return String((item || {}).status || '') === 'accepted';
    }).length;
    const status = completedCount === sections.length
      ? 'completed'
      : sections.includes(currentSection) ? 'current' : 'pending';
    const firstTitle = titleMap.get(sections[0]) || '';
    const lastTitle = titleMap.get(sections[sections.length - 1]) || '';
    const derivedGoal = sections.length === 1
      ? `完成《${firstTitle || `第 ${sections[0]} 节`}》的复检、修订与采用`
      : `从《${firstTitle || `第 ${sections[0]} 节`}》推进到《${lastTitle || `第 ${sections[sections.length - 1]} 节`}》`;
    const storedCompletionRule = String(group.completion_rule || '').trim();
    return {
      group_id: String(group.group_id || `phase-${index + 1}`),
      order: index + 1,
      section_indices: sections,
      range_label: sectionRangeLabel(sections),
      goal: String(group.goal || '').trim() || derivedGoal,
      completion_rule: /Brief|写作提要/u.test(storedCompletionRule)
        ? '组内小节按已确认方案逐节复检、修订并采用'
        : storedCompletionRule || '组内小节按已确认方案逐节复检、修订并采用',
      completed: completedCount,
      total: sections.length,
      status,
    };
  });
  const lines = [
    `本轮整篇回炉：${groups.length} 个阶段，已完成 ${completed}/${items.length}，剩余 ${remaining} 个小节`,
    ...groups.flatMap(group => [
      `${group.status === 'completed' ? '✓' : group.status === 'current' ? '▶' : '○'} 阶段 ${group.order}｜${group.range_label}（${group.completed}/${group.total}）`,
      `  目标：${group.goal}；完成条件：${group.completion_rule}`,
    ]),
    '',
    '逐节任务：',
    ...rows.map(row => `${row.status === 'completed' ? '✓' : row.status === 'current' ? '▶' : '○'} 第 ${row.section_index} 节${row.title ? `《${row.title}》` : ''}：${row.status === 'completed' ? row.checkpoint : row.status_label}`),
  ];
  if (items.length > visibleItems.length) lines.push(`… 另有 ${items.length - visibleItems.length} 个小节，选择“查看本轮修订队列”可查看完整清单。`);
  lines.push('按顺序逐节处理；当前节采用后，工作流自动进入下一项。');
  return {
    status: 'running',
    total: items.length,
    completed,
    remaining,
    current_section_index: currentSection,
    detail_view: 'workflow_queue_detail',
    detail_label: '查看任务详情',
    groups,
    items: rows,
    text: lines.join('\n'),
  };
}

function buildShortRevisionTaskOverview(task = {}, sectionTitles = [], plannedSections = 0) {
  const progress = buildShortRevisionQueueProgress(task, sectionTitles);
  if (!progress) return null;
  const titleMap = new Map((Array.isArray(sectionTitles) ? sectionTitles : [])
    .map(item => [Number((item || {}).section_index || 0), String((item || {}).title || '').trim()]));
  const planned = Number(plannedSections || 0) > 0
    ? Number(plannedSections)
    : Math.max(0, ...progress.items.map(item => Number(item.section_index || 0)));
  const affected = new Set(progress.items.map(item => Number(item.section_index || 0)));
  const preserved = Array.from({ length: planned }, (_, index) => index + 1).filter(index => !affected.has(index));
  const current = progress.items.find(item => item.status === 'current') || null;
  const currentTitle = current ? titleMap.get(current.section_index) || current.title || '' : '';
  const closureSteps = [
    { id: 'full_story_assembly', label: '重新合稿', status: 'pending' },
    { id: 'full_story_review', label: '全篇剧情与人物复检', status: 'pending' },
    { id: 'short_deslop', label: '去 AI 味精修', status: 'pending' },
    { id: 'final_check', label: '终检与收束', status: 'pending' },
  ];
  const phases = [
    {
      id: 'planning_projection',
      label: '已确认方案回写',
      status: 'completed',
      summary: '设定与小节大纲已回写，结构影响和看点价值已检查。',
    },
    {
      id: 'section_revision',
      label: '受影响小节逐节回炉',
      status: 'running',
      groups: progress.groups,
      items: progress.items,
    },
    {
      id: 'preserved_sections',
      label: '未受影响小节沿用',
      status: 'preserved',
      sections: preserved,
      summary: preserved.length ? `${sectionRangeLabel(preserved)}沿用现稿，只参加最终全篇复检。` : '没有直接沿用的小节。',
    },
    {
      id: 'whole_story_closure',
      label: '全篇收束',
      status: 'pending',
      items: closureSteps,
    },
  ];
  const taskTitle = String(task.task_display_title || task.working_title || task.user_goal || '整篇回炉');
  const lines = [
    `当前任务：${taskTitle}`,
    `总进度：规划回写已完成；逐节回炉 ${progress.completed}/${progress.total}；全篇收束待执行`,
    '',
    '任务阶段：',
    '✓ 1. 已确认方案回写：设定、大纲、结构影响与看点价值已收束',
    ...progress.groups.flatMap((group, index) => {
      const groupLines = [
        `${group.status === 'completed' ? '✓' : group.status === 'current' ? '▶' : '○'} ${index + 2}. ${group.range_label}逐节回炉（${group.completed}/${group.total}）`,
        `   ${group.goal}；完成条件：${group.completion_rule}`,
      ];
      return groupLines;
    }),
    preserved.length ? `＝ 未受影响小节：${sectionRangeLabel(preserved)}：沿用现稿，最终全篇复检时检查承接` : '',
    `○ ${progress.groups.length + 2}. 全篇收束：重新合稿 → 全篇审阅 → 去 AI 味 → 终检`,
    '',
    current
      ? `当前子任务：复检并局部回炉第 ${current.section_index} 节${currentTitle ? `《${currentTitle}》` : ''}`
      : '当前子任务：等待全篇收束',
    current ? '处理原则：继承现有正文，只修与新规划不一致的内容；通过双门并重新采用后自动进入下一子任务。' : '',
  ].filter(Boolean);
  return {
    status: 'running',
    workflow_id: String(task.workflow_id || ''),
    task_title: taskTitle,
    phases,
    current_subtask: current ? {
      id: `revision-section-${String(current.section_index).padStart(3, '0')}`,
      section_index: current.section_index,
      title: currentTitle,
      label: `复检并局部回炉第 ${current.section_index} 节${currentTitle ? `《${currentTitle}》` : ''}`,
      status: current.status,
      objective: '继承现有正文，对照已确认规划和当前 Brief 复检，只修偏离项。',
      completion_rule: '机器检查与故事质量判断通过，用户采用，并写入新的小节检查点。',
    } : null,
    preserved_sections: preserved,
    closure_steps: closureSteps,
    text: lines.join('\n'),
  };
}

const WORKFLOW_ROLE_LABELS = {
  workflow_preflight: '准备与边界确认',
  source_or_material: '素材与依据',
  brief_or_contract: '规划与写作合同',
  macro_contract: '全局规划',
  draft_or_execute: '正文或执行',
  machine_quality_gate: '确定性检查',
  quality_gate: '内容质量判断',
  state_integration: '状态与记忆回写',
  handoff_and_next: '收束与下一步',
};

const AUTHOR_PHASE_GOALS = {
  '资讯 / 素材 / 脑洞卡': '找到并确认一个值得写、能落地的故事入口。',
  '设定与人物': '确认人物欲望、关系压力、核心冲突、反转和结局承诺。',
  '节奏与全篇小节大纲': '确认全篇节奏、总小节、每节功能、钩子、爆点和承接。',
  '确认总节数与小节标题': '确认全篇总节数、每节标题、完稿边界和扩容缩容规则。',
  '当前节 Brief': '把当前节写成可直接执行且不临场改剧情的写作提要。',
  '只写当前节': '只完成当前节正文，不越过小节边界。',
  '双门验收与采用': '检查当前节的确定性质量和故事价值，通过后形成采用锚点。',
  '合稿 / 精修 / 发布检查': '完成全篇合稿、连续性审阅、表达精修和发布检查。',
  '故事核心': '确认作品承诺、人物发动机、世界规则和持续剧情引擎。',
  '总纲': '确认全书主线、阶段推进、成长与终局兑现。',
  '卷纲': '确认当前卷目标、阻力、代价、人物变化和跨卷接口。',
  '阶段细纲': '把当前剧情阶段拆成连续、可写、可承接的章节规划。',
  '章节 Brief': '锁定当前章视角、目标、阻力、动作、信息和章末承接。',
  '正文与验收': '只写当前章并完成机器质量门与创作质量门。',
  '人物 / 伏笔 / 时间线提交': '原子接受正文和事实增量，更新人物、伏笔、时间线与记忆。',
  '复盘与跨卷交接': '完成阶段复盘、卷级验收或跨卷交接。',
};

function buildWorkflowTaskOverview(task = {}, template = {}) {
  const stages = Array.isArray(template.stages) ? template.stages : [];
  if (!stages.length) return null;
  const completed = new Set(Array.isArray(((task.machine || {}).completed_stages))
    ? task.machine.completed_stages.map(String)
    : []);
  const currentStageId = String(task.current_stage || task.current_step || stages[0].stage_id || '');
  const roleMap = {
    ...(((template || {}).unit_lifecycle_contract || {}).stage_roles || {}),
    ...(((task || {}).unit_lifecycle || {}).stage_roles || {}),
  };
  const stageRows = stages.map((stageDef, index) => {
    const stageId = String(stageDef.stage_id || '');
    const status = completed.has(stageId) ? 'completed' : stageId === currentStageId ? 'current' : 'pending';
    const role = String(roleMap[stageId] || 'workflow_stage');
    const authorPhase = (((stageDef || {}).interaction_contract || {}).author_phase) || {};
    const authorPhaseLabel = userFacingAuthorPhaseLabel(stageId, authorPhase.label || WORKFLOW_ROLE_LABELS[role] || visibleStageLabel(stageDef));
    return {
      id: stageId,
      order: index + 1,
      label: String(authorPhase.label || visibleStageLabel(stageDef)),
      internal_label: String(stageDef.label || VISIBLE_STAGE_LABELS[stageId] || stageId),
      author_phase_id: String(authorPhase.id || role),
      author_phase_label: authorPhaseLabel,
      author_phase_order: Number(authorPhase.order || index + 1),
      role,
      status,
      completion_conditions: Array.isArray(stageDef.completion_conditions) ? stageDef.completion_conditions.slice() : [],
      description: String(stageDef.description || ''),
      transition_contract: stageDef.transition_contract || { allowed_next: stageDef.allowed_next || [] },
      interaction_contract: stageDef.interaction_contract || null,
    };
  });
  const phases = [];
  for (const row of stageRows) {
    let phase = phases.find(item => item.author_phase_id === row.author_phase_id);
    if (!phase) {
      phase = {
        id: `phase-${String(phases.length + 1).padStart(2, '0')}`,
        order: row.author_phase_order,
        author_phase_id: row.author_phase_id,
        role: row.role,
        label: row.author_phase_label,
        stages: [row],
      };
      phases.push(phase);
    } else {
      phase.stages.push(row);
    }
  }
  phases.sort((left, right) => left.order - right.order);
  phases.forEach((phase, index) => {
    phase.order = index + 1;
  });
  const currentRow = stageRows.find(item => item.status === 'current') || stageRows.find(item => item.status === 'pending') || null;
  const currentPhaseForLabel = currentRow
    ? phases.find(item => item.author_phase_id === currentRow.author_phase_id)
    : null;
  if (currentPhaseForLabel && currentRow.author_phase_label) currentPhaseForLabel.label = currentRow.author_phase_label;
  const currentPhaseId = currentRow ? currentRow.author_phase_id : '';
  const currentPhaseOrder = phases.find(item => item.author_phase_id === currentPhaseId)?.order || phases.length;
  for (const phase of phases) {
    phase.completed = phase.stages.filter(item => item.status === 'completed').length;
    phase.total = phase.stages.length;
    phase.status = phase.author_phase_id === currentPhaseId
      ? 'current'
      : phase.order < currentPhaseOrder ? 'completed' : 'pending';
  }
  const current = currentRow;
  const currentPhase = phases.find(item => item.status === 'current') || phases.find(item => item.status === 'pending') || null;
  const executionPoint = task.author_execution_point && typeof task.author_execution_point === 'object'
    ? task.author_execution_point
    : null;
  const taskTitle = String(task.task_display_title || task.working_title || task.user_goal || task.scope || task.workflow_type || '当前工作流');
  const completedCount = phases.filter(item => item.status === 'completed').length;
  const lines = [
    `当前任务：${taskTitle}`,
    `总进度：${completedCount}/${phases.length} 个创作阶段已完成`,
    '',
    '任务阶段：',
    ...phases.map(phase => `${phase.status === 'completed' ? '✓' : phase.status === 'current' ? '▶' : '○'} ${phase.order}. ${phase.label}`),
    '',
    currentPhase ? `当前阶段：${currentPhase.label}` : '当前阶段：等待任务收束',
    executionPoint && executionPoint.label ? `当前执行：${String(executionPoint.label)}` : '',
    currentPhase ? `完成目标：${AUTHOR_PHASE_GOALS[currentPhase.label] || '完成当前作者阶段并进入自然下一步。'}` : '',
    '交互原则：每次只推进当前作者阶段；内部检查自动执行，只有需要你决定时才显示数字选项。',
  ].filter(Boolean);
  return {
    status: String(task.status || 'running'),
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || ''),
    task_title: taskTitle,
    execution_point: executionPoint,
    task_form: String((((task || {}).scheduling_contract || {}).task_form) || (((template || {}).scheduling_contract || {}).task_form) || ''),
    phases,
    current_subtask: current,
    interaction_contract: current && current.interaction_contract
      ? current.interaction_contract
      : { menu_style: 'numbered_1_4', expose_as_top_level_task: false, parent_task_first: true },
    text: lines.join('\n'),
  };
}

function userFacingAuthorPhaseLabel(stageId, fallback) {
  if (String(stageId || '') === 'section_plan_lock') return '确认总节数与小节标题';
  return String(fallback || '');
}

function revisionQueueGroups(queue, items) {
  const groups = Array.isArray((queue || {}).groups) ? queue.groups : [];
  const valid = groups.map(group => ({
    ...group,
    section_indices: (Array.isArray((group || {}).section_indices) ? group.section_indices : [])
      .map(Number)
      .filter(sectionIndex => Number.isInteger(sectionIndex) && sectionIndex > 0),
  })).filter(group => group.section_indices.length > 0);
  if (valid.length) return valid;
  return items.reduce((result, item) => {
    const sectionIndex = Number(item.section_index);
    const current = result[result.length - 1];
    if (!current || sectionIndex !== current.section_indices[current.section_indices.length - 1] + 1) {
      result.push({ group_id: `phase-${String(result.length + 1).padStart(2, '0')}`, section_indices: [sectionIndex] });
    } else {
      current.section_indices.push(sectionIndex);
    }
    return result;
  }, []);
}

function sectionRangeLabel(sections) {
  if (!sections.length) return '未指定小节';
  const groups = sections.map(Number).filter(Number.isInteger).sort((a, b) => a - b).reduce((result, sectionIndex) => {
    const current = result[result.length - 1];
    if (!current || sectionIndex !== current[current.length - 1] + 1) result.push([sectionIndex]);
    else current.push(sectionIndex);
    return result;
  }, []);
  return groups.map(group => group.length === 1
    ? `第 ${group[0]} 节`
    : `第 ${group[0]}-${group[group.length - 1]} 节`).join('、');
}

function currentShortRevisionStep(task) {
  const stage = String(task.current_stage || ((task.stage_execution || {}).stage_id) || '');
  if (['first_section_brief', 'section_brief', 'next_section_brief'].includes(stage)) return '待准备并回炉';
  if (['draft_first_section', 'draft_section', 'draft_next_section'].includes(stage)) return '写作提要已通过，待写正文';
  if (stage === 'section_machine_gate') return '正文已生成，待机器检查';
  if (['quality_gate', 'story_value_gate'].includes(stage)) return '机器检查已通过，待故事质量检查';
  if (stage === 'section_repair_loop') return '质量检查发现问题，待修订';
  if (['section_candidate_compare', 'section_accept_anchor'].includes(stage)) return '质量检查已通过，待确认采用';
  return '进行中';
}

function buildShortSectionDecisionPendingAction(tpl, task) {
  const stageIds = new Set(((tpl || {}).stages || []).map((stage) => stage.stage_id));
  const revisionTarget = stageIds.has('feedback_impact_sync') ? 'feedback_impact_sync' : 'section_brief';
  const sectionMatch = String((task || {}).scope || '').match(/第\s*0*(\d+)\s*节/u);
  const sectionLabel = sectionMatch ? `第 ${Number(sectionMatch[1])} 节` : '当前节';
  return decoratePendingAction({
    id: `pa-section-decision-${String((task || {}).workflow_id || 'short')}`,
    question: '当前小节已通过验收，请选择如何处理',
    options: [
      {
        number: 1,
        action_id: 'accept_current_section',
        label: '采用；自动提交本节并生成下一节 Brief',
        target_stage: 'section_accept_anchor',
        risk_level: 'high',
        requires_user_confirm: true,
        execution_mode: 'accept_current_section',
        completion_boundary: 'anchor_committed_then_next_brief_ready',
      },
      {
        number: 2,
        action_id: 'request_revision_input',
        label: `修改${sectionLabel}；完成后继续后续任务`,
        target_stage: revisionTarget,
        risk_level: 'low',
        requires_user_confirm: false,
      },
      {
        number: 3,
        action_id: 'inspect_current_state',
        label: '查看本轮修订队列与依据',
        frontend_surface: 'workflow_queue_detail',
        risk_level: 'low',
        requires_user_confirm: false,
      },
      { number: 4, action_id: 'pause', label: '暂停并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
}

function visibleStageLabel(stageDef) {
  if (!stageDef) return '当前步骤';
  if (String(stageDef.stage_id || '') === 'section_plan_lock') return VISIBLE_STAGE_LABELS.section_plan_lock;
  const authorPhase = (((stageDef || {}).interaction_contract || {}).author_phase) || {};
  if (authorPhase.label) return String(authorPhase.label);
  return String(stageDef.label || VISIBLE_STAGE_LABELS[stageDef.stage_id] || stageDef.stage_id);
}

function decoratePendingAction(action) {
  const now = new Date();
  const compactOptions = action.compact_options === true;
  const options = normalizeVisibleOptions(action.options, action.free_text_enabled !== false, compactOptions);
  const stable = JSON.stringify({
    id: action.id || '',
    question: action.question || '',
    options: options.map((item) => ({
      number: item.number,
      action_id: item.action_id || item.action || '',
      label: item.label || '',
      target_stage: item.target_stage || '',
      target_scope: item.target_scope || '',
    })),
  });
  return {
    ...action,
    interaction_profile: compactOptions ? 'numeric_compact_choice' : 'numeric_four_choice',
    options,
    created_at: action.created_at || now.toISOString(),
    expires_at: action.expires_at || new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString(),
    visible_choice_hash: action.visible_choice_hash || crypto.createHash('sha256').update(stable).digest('hex'),
  };
}

function normalizeVisibleOptions(input, freeTextEnabled, compactOptions = false) {
  const raw = (Array.isArray(input) ? input : []).filter(Boolean);
  const recommendationIndex = Math.max(0, raw.findIndex((item) => item.recommended === true || /（推荐）/u.test(String(item.label || ''))));
  const primary = raw[recommendationIndex] || {
    action_id: 'inspect_current_state',
    label: '查看当前进度与依据',
    risk_level: 'low',
    requires_user_confirm: false,
  };
  if (compactOptions) {
    const compact = [primary, ...raw.filter((item, index) => index !== recommendationIndex)];
    return compact.map((item, index) => {
      const recommended = index === 0;
      const label = String(item.label || `选项 ${index + 1}`).replace(/（推荐）/gu, '').trim();
      return { ...item, number: index + 1, recommended, label: recommended ? `${label}（推荐）` : label };
    });
  }
  const reserved = new Set(['inspect_current_state', 'pause', 'free_text', 'show_task_inbox']);
  const business = raw.filter((item, index) => index !== recommendationIndex && !reserved.has(String(item.action_id || item.action || '')));
  const existingInspect = raw.find((item) => String(item.action_id || item.action || '') === 'inspect_current_state');
  const existingPause = raw.find((item) => String(item.action_id || item.action || '') === 'pause');
  const existingFree = raw.find((item) => String(item.action_id || item.action || '') === 'free_text');
  const existingInbox = raw.find((item) => String(item.action_id || item.action || '') === 'show_task_inbox');
  const options = [primary, ...business];

  if (options.length >= 3 && options.length < 4 && existingPause) options.push(existingPause);
  const primaryAction = String(primary.action_id || primary.action || '');
  if (options.length < 4 && primaryAction !== 'inspect_current_state') options.push(existingInspect || {
    action_id: 'inspect_current_state', label: '查看当前进度与依据', risk_level: 'low', requires_user_confirm: false,
  });
  if (options.length < 4) options.push(existingPause || {
    action_id: 'pause', label: '暂停并保存断点', risk_level: 'low', requires_user_confirm: false,
  });
  if (options.length < 4) options.push(freeTextEnabled
    ? (existingFree || { action_id: 'free_text', label: '输入其他要求', risk_level: 'low', requires_user_confirm: false })
    : (existingInbox || { action_id: 'show_task_inbox', label: '返回任务列表', risk_level: 'low', requires_user_confirm: false }));

  const chosen = options.slice(0, 4);
  while (chosen.length < 4) {
    chosen.push({ action_id: 'show_task_inbox', label: '返回任务列表', risk_level: 'low', requires_user_confirm: false });
  }
  return chosen.map((item, index) => {
    const recommended = index === 0;
    const label = String(item.label || `选项 ${index + 1}`).replace(/（推荐）/gu, '').trim();
    return {
      ...item,
      number: index + 1,
      recommended,
      label: recommended ? `${label}（推荐）` : label,
    };
  });
}

function normalizeRecommendations(value) {
  if (!value) return [];
  const raw = Array.isArray(value) ? value : [value];
  return raw
    .filter(Boolean)
    .slice(0, 4)
    .map((item, index) => {
      if (typeof item === 'string') {
        return { number: index + 1, action_id: 'start_new_workflow', label: item };
      }
      return {
        number: Number(item.number) || index + 1,
        action_id: String(item.action_id || item.action || 'start_new_workflow'),
        label: String(item.label || item.display || item.next_action || `下一步 ${index + 1}`),
        workflow_type: item.workflow_type ? String(item.workflow_type) : '',
        scope: item.scope ? String(item.scope) : '',
        risk_level: item.risk_level ? String(item.risk_level) : 'low',
      };
    });
}

function buildCompletionPendingAction(task, recommendations) {
  const options = recommendations.length > 0
    ? recommendations
    : [
        { number: 1, action_id: 'start_new_workflow', label: '开启新的写作任务', risk_level: 'low' },
        { number: 2, action_id: 'finish_session', label: '结束本轮', risk_level: 'low' },
      ];
  return decoratePendingAction({
    id: `pa-completed-${task.workflow_id || 'workflow'}`,
    question: '流程已完成，请选择下一步',
    options,
    free_text_enabled: true,
  });
}

function renderPendingActionText(action, intro = '') {
  const pending = action && typeof action === 'object' ? action : {};
  const lines = (Array.isArray(pending.options) ? pending.options : [])
    .slice(0, 4)
    .map((item, index) => `${index + 1}. ${String(item.label || `选项 ${index + 1}`)}`);
  return [String(intro || '').trim(), String(pending.question || '请选择下一步').trim(), '', ...lines, '', '回复 1/2/3/4。']
    .filter((line, index, values) => line !== '' || (index > 0 && values[index - 1] !== ''))
    .join('\n')
    .trim();
}

function projectTaskActionView(taskCard, intro = '') {
  const card = taskCard && typeof taskCard === 'object' ? taskCard : {};
  const options = normalizeVisibleOptions(card.next_actions, card.free_text_enabled !== false).map((item) => {
    if (item.interaction_mode || item.execution_command) return item;
    const actionId = String(item.action_id || item.action || '');
    if (actionId === 'inspect_current_state') {
      return {
        ...item,
        interaction_mode: 'execute_command',
        execution_command: 'node scripts/workflow-state-machine.js inspect --project-root . --json',
      };
    }
    if (actionId === 'show_task_inbox') {
      return {
        ...item,
        interaction_mode: 'execute_command',
        execution_command: 'node scripts/workflow-task-inbox.js --project-root . --json',
      };
    }
    if (['pause', 'free_text'].includes(actionId)) return { ...item, interaction_mode: 'semantic_only' };
    return item;
  });
  const boundaryHint = visibleExecutionBoundaryHint(card.execution_boundary || null);
  const summary = String(intro || '').trim() || [
    `当前任务：${String(card.title || '继续当前任务')}`,
    card.visible_stage ? `当前阶段：${String(card.visible_stage)}` : '',
    card.stop_reason ? `当前停靠：${String(card.stop_reason)}` : '',
    boundaryHint,
    card.last_trusted_artifact ? `最后可信产物：${String(card.last_trusted_artifact)}` : '',
  ].filter(Boolean).join('\n');
  const pending = {
    question: '请选择当前任务的下一步',
    options,
  };
  return {
    current_task: {
      id: String(card.id || ''),
      workflow_type: String(card.workflow_type || ''),
      title: String(card.title || ''),
      visible_stage: String(card.visible_stage || ''),
      stop_reason: String(card.stop_reason || ''),
      last_trusted_artifact: String(card.last_trusted_artifact || ''),
      status: String(card.status || ''),
      execution_boundary: card.execution_boundary || null,
    },
    execution_boundary: card.execution_boundary || null,
    next_actions: options,
    visible_menu: options.map((item, index) => `${index + 1}. ${String(item.label || `选项 ${index + 1}`)}`),
    visible_response: renderPendingActionText(pending, summary),
  };
}

function visibleExecutionBoundaryHint(boundary) {
  if (!boundary || typeof boundary !== 'object') return '';
  const mode = String(boundary.visible_execution_mode || '');
  if (mode === '协作模式' && boundary.stream_abort === false) {
    return '协作模式：可保存断点；不能中止宿主隐藏思考。';
  }
  if (mode) return `${mode}：按当前宿主能力执行。`;
  return '';
}

module.exports = {
  buildCompletionPendingAction,
  buildPendingAction,
  buildShortDraftPendingAction,
  buildShortRevisionQueueProgress,
  buildShortRevisionTaskOverview,
  buildWorkflowTaskOverview,
  buildReviewBatchPendingAction,
  buildReviewBatchReacceptancePendingAction,
  buildShortSectionDecisionPendingAction,
  buildShortSettingCandidatePendingAction,
  decoratePendingAction,
  normalizeRecommendations,
  normalizeSelectedAction,
  projectTaskActionView,
  renderPendingActionText,
  visibleStageLabel,
};
