#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const SCRIPT_DIR = path.resolve(__dirname, '..');

const RESULT_CONTRACT_V2_FIELDS = [
  'outputs',
  'changed_files',
  'evidence',
  'verification_result',
  'checkpoint_state',
  'output_health_result',
];
const LONG_WRITE_REVIEW_RETURNS = {
  master_outline_review: 'master_outline',
  volume_outline_review: 'volume_outline',
  detail_outline_review: 'stage_detail_outline',
  brief_review: 'chapter_brief',
  prose_acceptance: 'prose',
  milestone_review: 'chapter_commit',
  volume_acceptance: 'milestone_review',
  book_acceptance: 'volume_acceptance',
};
const LONG_WRITE_ASSET_TARGETS = {
  positioning: { kind: 'book', id: 'current-book' },
  story_bible: { kind: 'story_bible', id: 'current-story-bible' },
  master_outline: { kind: 'master_outline', id: 'current-master-outline' },
  master_outline_review: { kind: 'master_outline', id: 'current-master-outline' },
  volume_outline: { kind: 'volume', id: 'current-volume' },
  volume_outline_review: { kind: 'volume', id: 'current-volume' },
  stage_detail_outline: { kind: 'story_stage', id: 'current-story-stage' },
  detail_outline_review: { kind: 'story_stage', id: 'current-story-stage' },
  chapter_brief: { kind: 'chapter', id: 'current-chapter' },
  brief_review: { kind: 'chapter', id: 'current-chapter' },
  prose: { kind: 'chapter', id: 'current-chapter' },
  prose_acceptance: { kind: 'chapter', id: 'current-chapter' },
  chapter_commit: { kind: 'chapter', id: 'current-chapter' },
  milestone_review: { kind: 'milestone', id: 'current-milestone' },
  volume_acceptance: { kind: 'volume', id: 'current-volume' },
  book_acceptance: { kind: 'book', id: 'current-book' },
};
const LONG_WRITE_RESULT_FIELDS = [
  'asset_revision',
  'review_decision',
  'downstream_effects',
  'lifecycle_transition_request',
  'result_write_set',
];

const SHORT_STAGE_CONTEXT_MEMORY = new Set([
  'first_section_brief',
  'section_brief',
  'next_section_brief',
  'draft_first_section',
  'draft_section',
  'draft_next_section',
  'section_repair_loop',
  'quality_gate',
  'story_value_gate',
  'section_accept_anchor',
  'feedback_impact_sync',
  'feedback_apply_patch',
]);
const DETERMINISTIC_NO_MEMORY_STAGES = new Set([
  'section_machine_gate',
]);

const NO_STORY_MEMORY_WORKFLOWS = new Set(['project_setup', 'setup_update']);
const OPTIONAL_STORY_MEMORY_WORKFLOWS = new Set(['long_scan', 'short_scan', 'cover', 'download_import']);
const NO_MEMORY_UPDATE_WORKFLOWS = new Set(['project_setup', 'setup_update', 'cover']);
const WORKFLOW_MEMORY_BUDGETS = Object.freeze({
  long_startup: 3600,
  short_startup: 3000,
  long_write: 4200,
  short_write: 3600,
  private_short_startup: 3600,
  review_repair: 4200,
  short_review: 3600,
  long_analyze: 3200,
  short_analyze: 2800,
  deslop: 3000,
  long_scan: 1800,
  short_scan: 1800,
  cover: 1600,
  download_import: 2600,
  project_setup: 0,
  setup_update: 0,
});

function memoryNeedsForStage(workflowType, stageDef) {
  if (NO_STORY_MEMORY_WORKFLOWS.has(workflowType)) return [];
  if (/(?:scan|cover|setup)/u.test(workflowType)) return ['user_preferences'];
  if (/(?:analyze|review|deslop)/u.test(workflowType) || String(stageDef.owner_module || '') === 'story-review') {
    return ['accepted_facts', 'review_dependencies', 'confirmed_quality_rules', 'user_preferences'];
  }
  return [
    'accepted_facts',
    'active_cast',
    'active_promises',
    'confirmed_style_rules',
    'confirmed_quality_rules',
    'continuity_obligations',
    'canon_constraints',
    'user_preferences',
  ];
}

function stageMemoryContract(workflowType, stageDef) {
  const noMemory = NO_STORY_MEMORY_WORKFLOWS.has(workflowType);
  const deterministicNoMemory = DETERMINISTIC_NO_MEMORY_STAGES.has(String(stageDef.stage_id || ''));
  const shortStageContext = ['short_write', 'short_startup', 'private_short_startup'].includes(workflowType)
    && SHORT_STAGE_CONTEXT_MEMORY.has(String(stageDef.stage_id || ''));
  const readMode = noMemory || deterministicNoMemory
    ? 'none'
    : OPTIONAL_STORY_MEMORY_WORKFLOWS.has(workflowType) ? 'optional' : 'required';
  const updateMode = NO_MEMORY_UPDATE_WORKFLOWS.has(workflowType) || deterministicNoMemory ? 'none' : 'suggest';
  return {
    read_mode: readMode,
    context_source: noMemory || deterministicNoMemory ? 'none' : shortStageContext ? 'stage_context' : 'story_memory',
    profile: `${workflowType}.${String(stageDef.stage_id || 'stage')}`,
    needs: noMemory || deterministicNoMemory ? [] : memoryNeedsForStage(workflowType, stageDef),
    token_budget: noMemory || deterministicNoMemory || shortStageContext
      ? 0
      : Number(WORKFLOW_MEMORY_BUDGETS[workflowType] || 0),
    budget_policy: noMemory || deterministicNoMemory ? 'none' : shortStageContext ? 'stage_context_adaptive' : 'workflow_adaptive',
    receipt_required: readMode === 'required',
    update_mode: updateMode,
    projection_mode: updateMode === 'suggest' ? 'after_accept' : 'none',
  };
}

function workflowTaskForm(workflowType) {
  if (['long_write', 'short_write', 'private_short_startup'].includes(workflowType)) return 'bounded_loop';
  if (['review_repair', 'short_review', 'long_analyze', 'short_analyze'].includes(workflowType)) return 'map_reduce';
  if (['long_scan', 'short_scan'].includes(workflowType)) return 'long_running_family';
  if (['cover', 'deslop', 'download_import'].includes(workflowType)) return 'single_unit';
  return 'linear_pipeline';
}

function workflowUnitIdentity(workflowType) {
  if (workflowType === 'long_write') return 'lifecycle_node+chapter_identity';
  if (['short_write', 'private_short_startup'].includes(workflowType)) return 'section_index+stage_id';
  if (['review_repair', 'short_review'].includes(workflowType)) return 'review_scope+batch_id+dimension';
  if (['long_analyze', 'short_analyze'].includes(workflowType)) return 'source_identity+analysis_stage+batch_id';
  if (['long_scan', 'short_scan'].includes(workflowType)) return 'source_identity+ranking_window';
  return 'stage_id+declared_scope';
}

function workflowSchedulingContract(workflowType) {
  return {
    task_form: workflowTaskForm(workflowType),
    unit_identity: workflowUnitIdentity(workflowType),
    repeat_policy: {
      before_accept: 'new_attempt_supersedes_previous_candidate',
      after_accept: 'new_revision_attempt_preserves_accepted_snapshot',
      accepted_change_requires: 'declared_change_set',
      retry_budget: 1,
    },
    impact_policy: {
      expression_only: 'current_unit',
      planning_change: 'dependency_closure',
      structural_change: 'declared_scope_then_dependency_closure',
      new_goal: 'new_workflow',
    },
    concurrency_policy: {
      read_only: 'parallel',
      canonical_write: 'single_writer_lease',
      same_unit: 'one_active_attempt',
    },
  };
}

function stageTransitionContract(stageDef) {
  return {
    allowed_next: Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next.slice() : [],
    failure_return: String((((stageDef || {}).review_requirement || {}).failure_return) || ''),
    invalid_transition: 'reject',
  };
}

function stageInteractionContract(stageDef) {
  return {
    menu_style: 'numbered_1_4',
    expose_as_top_level_task: false,
    parent_task_first: true,
    chat_interruptible: true,
    show_progress_after_stage: true,
    confirmation_boundary: stageDef.requires_user_confirm ? 'before_canonical_write' : 'stage_contract',
  };
}

function ensureTemplateMemoryContracts(templateDef) {
  if (!templateDef || !Array.isArray(templateDef.stages)) return templateDef;
  const workflowType = String(templateDef.workflow_type || '');
  templateDef.scheduling_contract = templateDef.scheduling_contract && typeof templateDef.scheduling_contract === 'object'
    ? cloneJson(templateDef.scheduling_contract)
    : workflowSchedulingContract(workflowType);
  templateDef.stages = templateDef.stages.map((stageDef) => ({
    ...stageDef,
    memory_contract: stageDef.memory_contract && typeof stageDef.memory_contract === 'object'
      ? cloneJson(stageDef.memory_contract)
      : stageMemoryContract(workflowType, stageDef),
    transition_contract: {
      ...stageTransitionContract(stageDef),
      ...(stageDef.transition_contract && typeof stageDef.transition_contract === 'object'
        ? cloneJson(stageDef.transition_contract)
        : {}),
      allowed_next: Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next.slice() : [],
    },
    interaction_contract: {
      ...stageInteractionContract(stageDef),
      ...(stageDef.interaction_contract && typeof stageDef.interaction_contract === 'object'
        ? cloneJson(stageDef.interaction_contract)
        : {}),
      expose_as_top_level_task: false,
    },
  }));
  return templateDef;
}

const BASE_TEMPLATES = {
  long_startup: template('long_startup', 'stage_then_confirm', false, [
    stage('project_type_lock', 'story-workflow', [], ['market_positioning'], true, 'low', '确认新书类型、目标平台、题材方向、目标读者、篇幅和是否使用对标/拆文素材；不得直接写正文。'),
    stage('market_positioning', 'story-long-write', ['project_type_lock'], ['core_promise'], true, 'medium', '完成市场定位、题材卖点、读者承诺和差异化判断。'),
    stage('core_promise', 'story-long-write', ['market_positioning'], ['character_design'], true, 'medium', '锁定核心设定、金手指/核心能力、主线承诺、爽点承诺和不可偏离边界。'),
    stage('character_design', 'story-long-write', ['core_promise'], ['plot_engine'], true, 'medium', '设计主角、关键配角、反派、关系压力、人物不变量和成长曲线。'),
    stage('plot_engine', 'story-long-write', ['character_design'], ['macro_outline'], true, 'medium', '设计剧情引擎、冲突循环、钩子债表、升级节奏和长期可写性。'),
    stage('macro_outline', 'story-long-write', ['plot_engine'], ['volume_outline'], true, 'medium', '形成全书总纲、主线阶段、关键节点、卷级目标和风险点。'),
    stage('volume_outline', 'story-long-write', ['macro_outline'], ['first_detail_outline'], true, 'medium', '生成第一卷卷纲、卷内节奏、爆点安排、人物状态推进和卷尾承诺。'),
    stage('first_detail_outline', 'story-long-write', ['volume_outline'], ['start_ready_handoff'], true, 'medium', '生成前置细纲，至少覆盖开篇可写章节、章节标题、节尾钩子、人物状态和质量门。'),
    stage('start_ready_handoff', 'story-workflow', ['first_detail_outline'], [], false, 'low', '输出开写前交接包：下一步进入长篇日更/单章 workflow，而不是在启动流程里直接写正文。'),
  ], unitLifecycle('book_startup', {
    project_type_lock: 'workflow_preflight',
    market_positioning: 'source_or_material',
    core_promise: 'brief_or_contract',
    character_design: 'brief_or_contract',
    plot_engine: 'brief_or_contract',
    macro_outline: 'macro_contract',
    volume_outline: 'macro_contract',
    first_detail_outline: 'brief_or_contract',
    start_ready_handoff: 'handoff_and_next',
  })),
  short_startup: template('short_startup', 'stage_then_confirm', false, [
    stage('project_type_lock', 'story-workflow', [], ['material_source_choice'], true, 'low', '确认短篇目标平台、题材、目标情绪、是否从脑洞卡/素材库/新鲜素材进入；不得直接写正文。'),
    stage('material_source_choice', 'story-short-write', ['project_type_lock'], ['material_card'], true, 'low', '选择素材来源：检查未完成短篇、抓取或学习新鲜素材、从已有素材开写、审阅或回炉已有短篇。'),
    stage('material_card', 'story-short-write', ['material_source_choice'], ['short_setting'], true, 'medium', '形成素材卡/脑洞卡，锁定标题承诺、现实入口、爆点、反转、风险和可写路线。'),
    stage('short_setting', 'story-short-write', ['material_card'], ['platform_genre_lock'], true, 'medium', '生成短篇设定：人物、关系、动机、真实场景、核心冲突、情绪债和结尾价值。'),
    stage('platform_genre_lock', 'story-short-write', ['short_setting'], ['rhythm_pattern_selection'], true, 'medium', '一次只确认一个目标平台配置和一张题材方法卡，锁定开篇承诺、阅读停顿、结尾兑现、证据来源与可信度；确认前可继续聊天、纠偏或换方向，不写小纲或正文。'),
    stage('rhythm_pattern_selection', 'story-short-write', ['platform_genre_lock'], ['section_outline'], true, 'medium', '选择短篇节奏套路、爽点类型、反转方式和钩子兑现。'),
    stage('section_outline', 'story-short-write', ['rhythm_pattern_selection'], ['section_plan_lock'], true, 'medium', '生成小节大纲；每节必须同时锁定上一节钩子承接、压力变化、场景动作、可见阻力、角色选择、本节兑现、关系变化、代价与新钩子。连续查表/看文件不算剧情。'),
    stage('section_plan_lock', 'story-short-write', ['section_outline'], ['first_section_brief'], true, 'medium', '锁定总小节数、发布形态、当前第 1 节目标、全篇小节标题与扩容/缩容规则。标题必须展示给用户确认，无标题也要明确锁定。'),
    stage('first_section_brief', 'story-short-write', ['section_plan_lock'], ['start_ready_handoff'], true, 'medium', '生成第 1 节 Brief，锁定视角、人物称谓、场景物件、主动动作、节尾钩子和禁写漂移点；逐项映射第 1 节大纲合同的稳定 ID，不得临场改剧情。'),
    stage('start_ready_handoff', 'story-workflow', ['first_section_brief'], [], false, 'low', '输出开写前交接包：下一步进入短篇正文小节 workflow，而不是在启动流程里直接写正文。'),
  ], unitLifecycle('short_story_startup', {
    project_type_lock: 'workflow_preflight',
    material_source_choice: 'source_or_material',
    material_card: 'source_or_material',
    short_setting: 'brief_or_contract',
    platform_genre_lock: 'brief_or_contract',
    rhythm_pattern_selection: 'brief_or_contract',
    section_outline: 'brief_or_contract',
    section_plan_lock: 'brief_or_contract',
    first_section_brief: 'brief_or_contract',
    start_ready_handoff: 'handoff_and_next',
  })),
  project_setup: template('project_setup', 'stage_then_confirm', false, [
    stage('project_type_lock', 'story-workflow', [], ['runtime_setup'], true, 'low', '确认这是新项目初始化、已有项目迁移还是空目录准备写作；不创建正文。'),
    stage('runtime_setup', 'story-setup', ['project_type_lock'], ['directory_schema'], true, 'medium', '部署或刷新 hooks、rules、agents、scripts、references 和 .story-deployed。'),
    stage('directory_schema', 'story-setup', ['runtime_setup'], ['workflow_memory_init'], true, 'medium', '建立或确认长篇/短篇/拆文/导入所需目录结构，不覆盖用户资产。'),
    stage('workflow_memory_init', 'story-workflow', ['directory_schema'], ['start_ready_handoff'], false, 'low', '初始化 workflow 任务目录、偏好记忆、上下文入口和任务收件箱。'),
    stage('start_ready_handoff', 'story-workflow', ['workflow_memory_init'], [], false, 'low', '输出项目准备完成后的可选下一步：新长篇、新短篇、导入、拆文或审阅。'),
  ], unitLifecycle('project_setup', {
    project_type_lock: 'workflow_preflight',
    runtime_setup: 'state_integration',
    directory_schema: 'state_integration',
    workflow_memory_init: 'state_integration',
    start_ready_handoff: 'handoff_and_next',
  })),
  long_write: template('long_write', 'stage_then_confirm', false, [
    longformStage('positioning', 'story-long-write', [], ['story_bible'], false, 'low', '锁定平台、读者、题材、核心卖点和预期体量。'),
    longformStage('story_bible', 'story-long-write', ['positioning'], ['master_outline'], false, 'medium', '建立故事核心、人物不变量、世界规则和持续剧情引擎。'),
    longformStage('master_outline', 'story-long-write', ['story_bible'], ['master_outline_review'], false, 'medium', '设计全书主线、阶段、成长、升级和结局兑现。'),
    longformStage('master_outline_review', 'story-review', ['master_outline'], ['master_outline', 'volume_outline'], false, 'medium', '审阅总纲的故事核、因果链、长期承诺和可持续性。'),
    longformStage('volume_outline', 'story-long-write', ['master_outline_review'], ['volume_outline_review'], false, 'medium', '设计当前卷目标、阻力、代价、人物变化和跨卷承接。'),
    longformStage('volume_outline_review', 'story-review', ['volume_outline'], ['volume_outline', 'stage_detail_outline'], false, 'medium', '审阅当前卷对总纲的贡献及上下卷接口。'),
    longformStage('stage_detail_outline', 'story-long-write', ['volume_outline_review'], ['detail_outline_review'], false, 'medium', '按剧情阶段设计连续事件、因果、冲突升级和回收位置。'),
    longformStage('detail_outline_review', 'story-review', ['stage_detail_outline'], ['stage_detail_outline', 'chapter_brief'], false, 'medium', '审阅阶段细纲的基础可写性和按风险激活的专业维度。', 'detail_outline_quality_v1'),
    longformStage('chapter_brief', 'story-long-write', ['detail_outline_review'], ['brief_review'], false, 'medium', '锁定当前章节的视角、场景目标、阻力、动作、信息和承接。'),
    longformStage('brief_review', 'story-review', ['chapter_brief'], ['chapter_brief', 'prose'], false, 'medium', '确认 Brief 可写、与细纲一致且不把关键剧情留给正文临场生成。'),
    longformStage('prose', 'story-long-write', ['brief_review'], ['prose_acceptance'], true, 'high', '只生产已通过 Brief 的当前章节正文候选。'),
    longformStage('prose_acceptance', 'story-review', ['prose'], ['prose', 'chapter_commit'], false, 'medium', '执行当前正文的机器质量门和创作质量门。'),
    longformStage('chapter_commit', 'story-workflow', ['prose_acceptance'], ['chapter_brief', 'milestone_review'], false, 'high', '原子接受正文和事实增量，并投影到追踪与记忆。'),
    longformStage('milestone_review', 'story-review', ['chapter_commit'], ['chapter_commit', 'stage_detail_outline', 'chapter_brief', 'volume_acceptance'], false, 'medium', '在剧情阶段结束后复盘角色、主线、承诺、钩子和质量债。'),
    longformStage('volume_acceptance', 'story-review', ['milestone_review'], ['milestone_review', 'volume_outline', 'book_acceptance'], false, 'medium', '检查卷级兑现并完成跨卷交接。'),
    longformStage('book_acceptance', 'story-review', ['volume_acceptance'], ['volume_acceptance'], false, 'medium', '验收全书承诺、人物终局、钩子闭环、结构和发布资产。'),
  ], unitLifecycle('book_lifecycle', {
    positioning: 'workflow_preflight',
    story_bible: 'source_or_material',
    master_outline: 'macro_contract',
    master_outline_review: 'quality_gate',
    volume_outline: 'macro_contract',
    volume_outline_review: 'quality_gate',
    stage_detail_outline: 'macro_contract',
    detail_outline_review: 'quality_gate',
    chapter_brief: 'brief_or_contract',
    brief_review: 'quality_gate',
    prose: 'draft_or_execute',
    prose_acceptance: 'machine_quality_gate',
    chapter_commit: 'state_integration',
    milestone_review: 'quality_gate',
    volume_acceptance: 'quality_gate',
    book_acceptance: 'handoff_and_next',
  })),
  short_write: template('short_write', 'stage_then_confirm', false, [
    stage('project_type_lock', 'story-workflow', [], ['material_source_choice'], true, 'low', '确认短篇目标平台、题材、目标情绪和素材入口；不得直接写正文。'),
    stage('material_source_choice', 'story-short-write', ['project_type_lock'], ['material_card'], true, 'low', '选择检查现有素材、使用已有素材、学习新鲜素材或直接输入脑洞。'),
    stage('material_card', 'story-short-write', ['material_source_choice'], ['short_setting'], false, 'low'),
    stage('short_setting', 'story-short-write', ['material_card'], ['platform_genre_lock'], false, 'medium'),
    stage('platform_genre_lock', 'story-short-write', ['short_setting'], ['rhythm_pattern_selection'], true, 'medium', '一次只确认一个目标平台配置和一张题材方法卡，锁定开篇承诺、阅读停顿、结尾兑现、证据来源与可信度；确认前可继续聊天、纠偏或换方向，只更新设定与大纲元数据。'),
    stage('rhythm_pattern_selection', 'story-short-write', ['platform_genre_lock'], ['section_outline'], true, 'medium', '在平台题材契约确认后，选择短篇主节奏/辅节奏、爽点套路、反转方式和兑现方式；至少覆盖爽文打脸、公开审判、亲情断亲、追妻火葬场、死人文学、规则怪谈、身份反转、重生复仇等候选，并写入设定.md。'),
    stage('section_outline', 'story-short-write', ['rhythm_pattern_selection'], ['section_plan_lock'], false, 'medium', '生成并验收小节故事引擎：上一节钩子承接、压力变化、场景动作、可见阻力、角色选择、本节兑现、关系变化和代价必须齐全；重复钩子/兑现或另起无关调查线均阻断；高潮兑现核心承诺，结尾落责任后果。'),
    stage('section_plan_lock', 'story-short-write', ['section_outline'], ['short_structure_impact_audit'], true, 'medium', '锁定短篇总小节数、目标字数带、发布形态、每节功能、小节标题、当前节序号和全篇完成分支；标题必须展示并取得用户确认，无标题也要明确锁定。未确定总小节/完成条件/标题锁，不得进入 Brief 或正文。扩容、缩容、插节、合并、删节和重排必须回到这里。'),
    stage('short_structure_impact_audit', 'story-short-write', ['section_plan_lock'], ['hook_value_gate'], false, 'medium', '检查扩容/缩容/插节/合并/删节/重排对素材卡、设定、节奏套路、小节大纲、已生成 Brief、采用锚点、候选稿、正文索引和发布合并稿的影响；输出保留/失效/重算清单，通过后才进入看点价值门。'),
    stage('hook_value_gate', 'story-short-write', ['short_structure_impact_audit'], ['short_setting', 'section_outline', 'section_brief'], false, 'medium', '核对标题承诺、人物动机、现实因果、冲突升级、爽点、爆点、情绪债、节尾钩子；完整但不吸引人必须回设定或小节大纲重构，不得直接写正文。'),
    stage('section_brief', 'story-short-write', ['hook_value_gate'], ['draft_section'], false, 'medium', '生成当前小节 Brief，锁定视角、人物称谓、主角主动动作、场景物件、因果推进、节尾钩子和禁写漂移点。必须逐项映射当前小节大纲合同的稳定 ID，不得换掉核心爆点或后果。生成后停在正文写前确认，不自动写正文。'),
    stage('draft_section', 'story-short-write', ['section_brief'], ['section_machine_gate'], true, 'high', '每次只写一个小节，完成后必须进入当前小节机器门，不得连续追加下一节。'),
    stage('section_machine_gate', 'story-short-write', ['current_section_draft'], ['section_repair_loop', 'story_value_gate'], false, 'medium', '运行当前小节机器门：字数/格式、AI 句式、工程词、破折号密度、退化/复读。blocking 未清零时只进入 section_repair_loop。'),
    stage('section_repair_loop', 'story-short-write', ['section_machine_gate'], ['section_machine_gate'], false, 'medium', '只修当前小节机器门 blocking，保留事实、人物、钩子和小节功能；修完回机器门复扫。'),
    stage('story_value_gate', 'story-short-write', ['section_machine_gate'], ['feedback_impact_sync', 'section_brief', 'section_accept_anchor'], false, 'medium', '后台审查当前小节是否值得读：人物动机、现实因果、冲突升级、爽点/爆点、主角能动性、节尾钩子、大纲忠实度和本节功能完成。十一项判断与每个大纲 ID 都必须引用正文原句；空泛的「均通过」无效。通过后统一显示正文采用决策。'),
    stage('feedback_impact_sync', 'story-workflow', [], ['feedback_apply_patch'], false, 'medium', '只读分析用户反馈影响层级：表达层、当前 Brief、规划层或结构层；输出受影响文件、保留项、失效项、重算项、建议回写顺序，以及 revision_groups（每组目标、小节范围、完成条件），不直接修改正文或规划资产。影响两个及以上小节、跨节钩子、压力曲线或高潮/结尾职责时必须先回受影响范围的小节大纲，不得从 Brief 或正文补写开始；只展示 workflow 返回的作者选项，不发明命令。'),
    stage('feedback_apply_patch', 'story-short-write', ['feedback_impact_sync'], ['section_repair_loop', 'section_brief', 'short_setting', 'section_outline', 'section_plan_lock'], true, 'high', '按已确认的影响计划回写：表达层只修当前节；当前节故事调整先重建 Brief；人物动机、关键因果、反转、节奏或后续承接冲突先更新设定/小节大纲并使旧 Brief 失效；扩缩容、插节、合并、删节或重排先回计划锁定和结构影响审计。跨节回写必须继承 revision_groups，供作者查看阶段目标并逐节推进。'),
    stage('section_accept_anchor', 'story-short-write', ['story_value_gate'], ['next_section_brief', 'full_story_assembly'], true, 'medium', '采用当前小节为 canonical 正文，记录小节摘要、人物状态、承接钩子、质量门结果、当前节序号和剩余小节；未写锚点不得生成下一节。若总小节已完成，进入全篇组装。'),
    stage('next_section_brief', 'story-short-write', ['section_accept_anchor'], ['draft_section'], false, 'medium', '自动生成下一小节 Brief，读取已采用小节锚点、正文末尾、用户反馈和质量债，并校验作品内篇幅基准；明显偏离时调整目标或记录结构例外理由。生成后停在正文写前确认，不自动写正文。'),
    stage('full_story_assembly', 'story-short-write', ['section_accept_anchor'], ['full_story_review'], false, 'medium', '确认所有计划小节均已采用，合并/整理正文.md，生成全篇节序索引、缺节检查、节尾承接检查和发布前完整稿。'),
    stage('full_story_review', 'story-review', ['full_story_assembly'], ['deslop', 'feedback_impact_sync'], false, 'medium', '执行一次全篇总编辑验收：开篇场景化与信息负载、小节功能/篇幅曲线、配角主动性、对手动机、主角身份效用、高潮跑道、结尾后果和标题承诺必须引用正文证据。通过后进入表达清理；需要回炉时把问题交给反馈影响链，先确认规划回写范围，不直接改正文。'),
    stage('deslop', 'story-short-write', ['full_story_review'], ['final_check'], false, 'medium', '只在故事层可进入表达清理后处理 AI 套话、重复解释、工程词和标点；提交前必须比较去 AI 前后逐节篇幅与全篇删损。显著删损时只补回动作、反应、后果和承接，不按字数差额机械灌水。'),
    stage('final_check', 'story-short-write', ['deslop'], [], false, 'low', '验证节数、正式稿哈希、去 AI 保真回执和发布完整性；只有“去 AI 后保真通过”或作者明确接受结构例外才可完成。'),
  ], unitLifecycle('section', {
    project_type_lock: 'workflow_preflight',
    material_source_choice: 'source_or_material',
    material_card: 'source_or_material',
    short_setting: 'brief_or_contract',
    platform_genre_lock: 'brief_or_contract',
    rhythm_pattern_selection: 'brief_or_contract',
    section_outline: 'brief_or_contract',
    section_plan_lock: 'brief_or_contract',
    short_structure_impact_audit: 'quality_gate',
    hook_value_gate: 'quality_gate',
    section_brief: 'brief_or_contract',
    draft_section: 'draft_or_execute',
    section_machine_gate: 'machine_quality_gate',
    section_repair_loop: 'draft_or_execute',
    story_value_gate: 'quality_gate',
    feedback_impact_sync: 'review_or_validate',
    feedback_apply_patch: 'brief_or_contract',
    section_accept_anchor: 'state_integration',
    next_section_brief: 'brief_or_contract',
    full_story_assembly: 'state_integration',
    full_story_review: 'quality_gate',
    deslop: 'quality_gate',
    final_check: 'handoff_and_next',
  })),
  review_repair: template('review_repair', 'stage_then_confirm', false, [
    stage('range_lock', 'story-workflow', [], ['evidence_scan'], false, 'low'),
    stage('evidence_scan', 'story-review', ['range_lock'], ['classify_findings'], false, 'medium'),
    stage('classify_findings', 'story-review', ['evidence_scan'], ['repair_plan'], false, 'medium'),
    stage('repair_plan', 'story-review', ['classify_findings'], ['user_scope_choice'], false, 'medium'),
    stage('user_scope_choice', 'story-workflow', ['repair_plan'], ['repair_execution_plan'], true, 'medium'),
    stage('repair_execution_plan', 'story-workflow', ['user_scope_choice'], ['staged_repair_candidate'], false, 'medium'),
    stage('staged_repair_candidate', 'story-long-write', ['repair_execution_plan'], ['repair_machine_gate'], false, 'high'),
    stage('repair_machine_gate', 'story-workflow', ['staged_repair_candidate'], ['staged_repair_candidate', 'execute_repair'], false, 'medium'),
    stage('execute_repair', 'story-long-write', ['repair_machine_gate'], ['recheck'], true, 'high'),
    stage('recheck', 'story-review', ['execute_repair'], ['closure'], false, 'medium'),
    stage('closure', 'story-workflow', ['recheck'], [], false, 'low'),
  ], unitLifecycle('range_or_fix_item', {
    range_lock: 'workflow_preflight',
    evidence_scan: 'source_or_material',
    classify_findings: 'quality_gate',
    repair_plan: 'brief_or_contract',
    user_scope_choice: 'brief_or_contract',
    repair_execution_plan: 'brief_or_contract',
    staged_repair_candidate: 'draft_or_execute',
    repair_machine_gate: 'machine_quality_gate',
    execute_repair: 'state_integration',
    recheck: 'quality_gate',
    closure: 'handoff_and_next',
  })),
  short_review: template('short_review', 'stage_then_confirm', false, [
    stage('scope_lock', 'story-workflow', [], ['plan_contract'], false, 'low', '锁定当前短篇项目、完整作品或用户指定小节范围；只读验收，不修改正文、设定或小节大纲。'),
    stage('plan_contract', 'story-review', ['scope_lock'], ['review_plan'], false, 'low', '只运行一次短篇验收入口，核对正文来源、素材卡、设定、小节大纲、总节数、跨节钩子和高潮/结尾职责。没有可审阅正文才阻断；规划格式或内容风险逐节记录，但不阻止只读正文审阅。'),
    stage('review_plan', 'story-review', ['plan_contract'], ['review_execute'], false, 'low', '生成紧凑 Evidence Plan：覆盖每一小节、相邻承接和全篇兑现；规划存在风险时把规划兑现结论标为暂定，同时保留逐节补全清单，不把内部批次或 agent 数量暴露给作者。'),
    stage('review_execute', 'story-review', ['review_plan'], ['continuity_synthesis'], false, 'medium', '按计划执行逐节只读审阅；每节必须有 verdict 和证据，不能只展示最严重的若干节后暗示其余小节无问题。'),
    stage('continuity_synthesis', 'story-review', ['review_execute'], ['review_report'], false, 'medium', '综合跨节因果、人物连续性、钩子回收、压力曲线、高潮兑现、结尾后果和平台阅读体验。'),
    stage('review_report', 'story-review', ['continuity_synthesis'], ['user_scope_choice'], false, 'medium', '输出全篇验收报告、逐节状态表和分级修复队列；默认只读，不覆盖创作资产。'),
    stage('user_scope_choice', 'story-workflow', ['review_report'], ['repair_handoff'], true, 'low', '向作者展示四个数字选项：全部修复、先修高价值项、只保存报告、输入其他要求；推荐项必须标注（推荐）。'),
    stage('repair_handoff', 'story-workflow', ['user_scope_choice'], ['closure'], false, 'medium', '根据作者选择创建或恢复短篇回炉任务，把受影响层级交回 short_write；审阅模块不得直接改稿。'),
    stage('closure', 'story-workflow', ['repair_handoff'], [], false, 'low', '保存验收结论、修复任务关系与下一步，不把审阅任务拆成多个作者任务。'),
  ], unitLifecycle('short_story_review', {
    scope_lock: 'workflow_preflight',
    plan_contract: 'quality_gate',
    review_plan: 'brief_or_contract',
    review_execute: 'review_or_validate',
    continuity_synthesis: 'quality_gate',
    review_report: 'state_integration',
    user_scope_choice: 'brief_or_contract',
    repair_handoff: 'state_integration',
    closure: 'handoff_and_next',
  })),
  long_analyze: template('long_analyze', 'full_auto', true, [
    stage('source_preflight', 'story-long-analyze', [], ['chapter_index'], false, 'low'),
    stage('chapter_index', 'story-long-analyze', ['source_preflight'], ['batch_extract'], false, 'low'),
    stage('batch_extract', 'story-long-analyze', ['chapter_index'], ['grounding_check'], false, 'medium'),
    stage('grounding_check', 'story-long-analyze', ['batch_extract'], ['aggregate'], false, 'medium'),
    stage('aggregate', 'story-long-analyze', ['grounding_check'], ['craft_absorption'], false, 'medium'),
    stage('craft_absorption', 'story-long-analyze', ['aggregate'], ['final_report'], false, 'medium'),
    stage('final_report', 'story-long-analyze', ['craft_absorption'], [], false, 'low'),
  ]),
  long_scan: template('long_scan', 'full_auto', true, [
    stage('scan_preflight', 'story-long-scan', [], ['source_lock'], false, 'low', '确认目标平台、题材方向、时间窗口和数据获取边界；不把历史印象当作当前榜单。'),
    stage('source_lock', 'story-long-scan', ['scan_preflight'], ['scan_execute'], false, 'medium', '锁定官方、用户提供或明确标注的辅助数据源，记录抓取时间、来源与适用范围。'),
    stage('scan_execute', 'story-long-scan', ['source_lock'], ['trend_validation'], false, 'medium', '采集并归一化榜单样本，提取可复核的题材、书名、指标和跨样本模式。'),
    stage('trend_validation', 'story-long-scan', ['scan_execute'], ['artifact_assembly'], false, 'medium', '验证样本覆盖、时间有效性、来源标注与趋势证据；不足时保留观察项，不升级为选题结论。'),
    stage('artifact_assembly', 'story-long-scan', ['trend_validation'], ['closure'], false, 'medium', '生成扫榜报告、趋势信号、选题候选和作者吸收卡，并保留数据来源与验证证据。'),
    stage('closure', 'story-workflow', ['artifact_assembly'], [], false, 'low', '交接可验证的市场输入与下一步选题或拆文建议，不直接改写书籍设定。'),
  ], unitLifecycle('scan_batch', {
    scan_preflight: 'workflow_preflight',
    source_lock: 'source_or_material',
    scan_execute: 'draft_or_execute',
    trend_validation: 'quality_gate',
    artifact_assembly: 'state_integration',
    closure: 'handoff_and_next',
  })),
  short_scan: template('short_scan', 'full_auto', true, [
    stage('scan_preflight', 'story-short-scan', [], ['source_lock'], false, 'low', '确认短篇平台、情绪赛道、样本窗口和数据获取边界；不把旧风口当作当前结论。'),
    stage('source_lock', 'story-short-scan', ['scan_preflight'], ['scan_execute'], false, 'medium', '锁定官方、用户提供或明确标注的辅助数据源，记录抓取时间、来源与有效期。'),
    stage('scan_execute', 'story-short-scan', ['source_lock'], ['trend_validation'], false, 'medium', '采集并归一化短篇榜单样本，提取情绪触发、传播点、题材标签和饱和风险。'),
    stage('trend_validation', 'story-short-scan', ['scan_execute'], ['artifact_assembly'], false, 'medium', '验证样本覆盖、时间有效性、来源标注与趋势证据；不把单点样本写成可复制的故事结构。'),
    stage('artifact_assembly', 'story-short-scan', ['trend_validation'], ['closure'], false, 'medium', '生成短篇市场报告、情绪趋势、选题候选和复扫时间，并保留来源与验证证据。'),
    stage('closure', 'story-workflow', ['artifact_assembly'], [], false, 'low', '交接市场输入给短篇创作或拆文，不直接生成短篇正文。'),
  ], unitLifecycle('scan_batch', {
    scan_preflight: 'workflow_preflight',
    source_lock: 'source_or_material',
    scan_execute: 'draft_or_execute',
    trend_validation: 'quality_gate',
    artifact_assembly: 'state_integration',
    closure: 'handoff_and_next',
  })),
  short_analyze: template('short_analyze', 'full_auto', true, [
    stage('analysis_preflight', 'story-short-analyze', [], ['source_lock'], false, 'low', '确认合法持有的拆解对象、目标范围、模式和续跑状态；拆解只读，不写新故事正文。'),
    stage('source_lock', 'story-short-analyze', ['analysis_preflight'], ['analysis_execute'], false, 'medium', '锁定原文来源、可读范围、章节或段落切片及禁抄边界，避免混入无来源推断。'),
    stage('analysis_execute', 'story-short-analyze', ['source_lock'], ['source_validation'], false, 'medium', '提取故事核、情绪结构、人物关系变化、反转铺垫和可迁移技巧，并建立原文证据关联。'),
    stage('source_validation', 'story-short-analyze', ['analysis_execute'], ['artifact_assembly'], false, 'medium', '验证覆盖范围、证据对应、禁抄边界和输出完整性；证据不足的结论必须降级为待验证项。'),
    stage('artifact_assembly', 'story-short-analyze', ['source_validation'], ['closure'], false, 'medium', '生成拆文报告、情节节点、写作手法、元数据和受限 memory_updates 建议。'),
    stage('closure', 'story-workflow', ['artifact_assembly'], [], false, 'low', '交接技巧卡与结构启发，要求下游重新确认新故事的因果、人物和结尾承诺。'),
  ], unitLifecycle('analysis_batch', {
    analysis_preflight: 'workflow_preflight',
    source_lock: 'source_or_material',
    analysis_execute: 'draft_or_execute',
    source_validation: 'quality_gate',
    artifact_assembly: 'state_integration',
    closure: 'handoff_and_next',
  })),
  cover: template('cover', 'stage_then_confirm', false, [
    stage('cover_preflight', 'story-cover', [], ['input_lock'], false, 'low', '确认书名、作者名、平台尺寸、输出目录、参考图与现有封面状态；封面不修改叙事资产。'),
    stage('input_lock', 'story-cover', ['cover_preflight'], ['visual_direction'], false, 'low', '锁定书籍信息、题材、视觉关键词、平台规格、目标文件和覆盖策略。'),
    stage('visual_direction', 'story-cover', ['input_lock'], ['generation_confirmation'], false, 'medium', '形成可审阅的题材视觉方向、提示词与输出命名方案，明确是否新建或覆盖既有封面。'),
    stage('generation_confirmation', 'story-workflow', ['visual_direction'], ['generate_cover_execute'], true, 'high', '在调用图像生成或覆盖任何现有封面前，必须取得用户对视觉方向、目标文件和覆盖策略的明确确认。'),
    stage('generate_cover_execute', 'story-cover', ['generation_confirmation'], ['output_validation'], true, 'high', '按已确认的提示词生成封面或执行已确认的覆盖，保存版本化源文件与提示词副本。'),
    stage('output_validation', 'story-cover', ['generate_cover_execute'], ['artifact_assembly'], false, 'medium', '验证图像可打开、尺寸比例、书名与作者名可读性、无水印和目标平台安全区。'),
    stage('artifact_assembly', 'story-cover', ['output_validation'], ['closure'], false, 'medium', '整理封面文件、提示词、规格、验证记录和可复用的视觉方向交接包。'),
    stage('closure', 'story-workflow', ['artifact_assembly'], [], false, 'low', '交接已验证的封面产物与路径；不得把封面方向反向写入故事设定。'),
  ], unitLifecycle('cover_asset', {
    cover_preflight: 'workflow_preflight',
    input_lock: 'source_or_material',
    visual_direction: 'brief_or_contract',
    generation_confirmation: 'brief_or_contract',
    generate_cover_execute: 'draft_or_execute',
    output_validation: 'quality_gate',
    artifact_assembly: 'state_integration',
    closure: 'handoff_and_next',
  })),
  download_import: template('download_import', 'full_auto', true, [
    stage('query_lock', 'story-import', [], ['source_discovery'], false, 'low'),
    stage('source_discovery', 'story-import', ['query_lock'], ['candidate_verify'], false, 'medium'),
    stage('candidate_verify', 'story-import', ['source_discovery'], ['download_or_import'], false, 'medium'),
    stage('download_or_import', 'story-import', ['candidate_verify'], ['quality_reconcile'], true, 'high'),
    stage('quality_reconcile', 'story-import', ['download_or_import'], ['handoff'], false, 'medium'),
    stage('handoff', 'story-import', ['quality_reconcile'], [], false, 'low'),
  ]),
  deslop: template('deslop', 'stage_then_confirm', false, [
    stage('scope_lock', 'story-deslop', [], ['diagnose'], false, 'low'),
    stage('diagnose', 'story-deslop', ['scope_lock'], ['repair_copy_or_in_place'], false, 'medium'),
    stage('repair_copy_or_in_place', 'story-deslop', ['diagnose'], ['fact_preservation'], true, 'high'),
    stage('fact_preservation', 'story-deslop', ['repair_copy_or_in_place'], ['prose_gate'], false, 'medium'),
    stage('prose_gate', 'story-deslop', ['fact_preservation'], ['closure'], false, 'medium'),
    stage('closure', 'story-deslop', ['prose_gate'], [], false, 'low'),
  ]),
  setup_update: template('setup_update', 'stage_then_confirm', false, [
    stage('version_check', 'story-setup', [], ['deployment_check'], false, 'low'),
    stage('deployment_check', 'story-setup', ['version_check'], ['refresh_runtime'], false, 'low'),
    stage('refresh_runtime', 'story-setup', ['deployment_check'], ['migration_decision'], true, 'high'),
    stage('migration_decision', 'story-setup', ['refresh_runtime'], ['verification'], true, 'high'),
    stage('verification', 'story-setup', ['migration_decision'], [], false, 'low'),
  ]),
};

// Public short writing and every private enhancement share this production
// kernel. Private registries may add material/learning stages, but cannot
// replace section transaction, context, gates, memory projection or assembly.
BASE_TEMPLATES.short_write.production_kernel = 'short-section-production-v2';

function template(workflowType, defaultCompletionPolicy, safeFullAuto, stages, unitLifecycleContract) {
  return ensureTemplateMemoryContracts({
    workflow_type: workflowType,
    default_completion_policy: defaultCompletionPolicy,
    safe_full_auto: safeFullAuto,
    unit_lifecycle_contract: unitLifecycleContract || unitLifecycle('workflow_batch', {}),
    result_contract: resultContractV2(workflowType),
    recovery: recoveryContract(),
    stages,
  });
}

function resultContractV2(workflowType) {
  const requiredFields = RESULT_CONTRACT_V2_FIELDS.concat(workflowType === 'long_write' ? LONG_WRITE_RESULT_FIELDS : []);
  return { version: 2, required_fields: requiredFields };
}

function recoveryContract() {
  return {
    preserve_last_trusted_artifact: true,
    resume_from: 'last_trusted_artifact_or_current_stage',
    on_missing_result_packet: 'run_workflow_recover_before_reexecution',
    on_output_failure: 'pause_at_checkpoint_and_record_blocking_reason',
  };
}

function unitLifecycle(unitType, stageRoles) {
  return {
    unit_type: unitType,
    stage_roles: stageRoles,
    required_sequence: ['brief_or_contract', 'draft_or_execute', 'machine_quality_gate', 'quality_gate', 'state_integration', 'handoff_and_next'],
    closure_rule: 'stage_done_is_not_workflow_done; always emit handoff/recommended_next before completed',
    failure_policy: 'stall_or_bad_output_blocks_current_unit_not_entire_project; preserve last trusted artifact',
  };
}

function stage(stageId, ownerModule, requiredInputs, allowedNext, requiresUserConfirm, riskLevel, description) {
  return {
    stage_id: stageId,
    owner_module: ownerModule,
    required_inputs: requiredInputs,
    completion_conditions: [`${stageId}.completed`],
    allowed_next: allowedNext,
    requires_user_confirm: requiresUserConfirm,
    risk_level: riskLevel,
    description: description || '',
  };
}

function longformStage(stageId, ownerModule, requiredInputs, allowedNext, requiresUserConfirm, riskLevel, description, resultContract) {
  const failureReturn = LONG_WRITE_REVIEW_RETURNS[stageId] || '';
  return {
    ...stage(stageId, ownerModule, requiredInputs, allowedNext, requiresUserConfirm, riskLevel, description),
    lifecycle_node: stageId,
    asset_target: { ...LONG_WRITE_ASSET_TARGETS[stageId] },
    review_requirement: failureReturn
      ? { required: true, failure_return: failureReturn }
      : { required: false, failure_return: '' },
    write_set: longformStageWriteSet(stageId, ownerModule),
    ...(resultContract ? { result_contract: resultContract } : {}),
  };
}

function longformStageWriteSet(stageId, ownerModule) {
  if (ownerModule === 'story-review') return ['追踪/**'];
  if (['positioning', 'story_bible'].includes(stageId)) return ['设定/**', '追踪/**'];
  if (['master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief'].includes(stageId)) {
    return ['大纲/**', '追踪/**'];
  }
  if (stageId === 'prose') return ['追踪/story-system/work/**'];
  if (stageId === 'chapter_commit') return ['正文/**', '追踪/**'];
  return ['追踪/**'];
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function registryRoots(extraRoot, noDefaultRoots) {
  const home = os.homedir();
  const envSkillDir = process.env.NOVEL_ASSISTANT_SKILL_DIR || '';
  const scriptRoot = path.resolve(SCRIPT_DIR, '..');
  const sourceCheckoutMode =
    fs.existsSync(path.join(scriptRoot, 'src', 'internal-skills')) ||
    fs.existsSync(path.join(scriptRoot, 'skills', 'novel-assistant', 'SKILL.md'));
  const includeInstalledPrivateRoots = !sourceCheckoutMode || Boolean(envSkillDir);
  const sourcePrivateRoot = path.join(SCRIPT_DIR, '..', 'src', 'private-internal-skills');
  const roots = sourceCheckoutMode ? [
    path.join(SCRIPT_DIR, '..', 'skills', 'novel-assistant', 'references', 'private-internal-skills'),
    path.join(SCRIPT_DIR, '..', 'references', 'private-internal-skills'),
    envSkillDir ? path.join(envSkillDir, 'references', 'private-internal-skills') : '',
    includeInstalledPrivateRoots ? path.join(home, '.codex', 'skills', 'novel-assistant', 'references', 'private-internal-skills') : '',
    includeInstalledPrivateRoots ? path.join(home, '.claude', 'skills', 'novel-assistant', 'references', 'private-internal-skills') : '',
    sourcePrivateRoot,
  ] : [
    sourcePrivateRoot,
    path.join(SCRIPT_DIR, '..', 'skills', 'novel-assistant', 'references', 'private-internal-skills'),
    path.join(SCRIPT_DIR, '..', 'references', 'private-internal-skills'),
    envSkillDir ? path.join(envSkillDir, 'references', 'private-internal-skills') : '',
    includeInstalledPrivateRoots ? path.join(home, '.codex', 'skills', 'novel-assistant', 'references', 'private-internal-skills') : '',
    includeInstalledPrivateRoots ? path.join(home, '.claude', 'skills', 'novel-assistant', 'references', 'private-internal-skills') : '',
  ];
  const selected = noDefaultRoots ? [] : roots.filter(Boolean);
  if (extraRoot) selected.unshift(path.resolve(extraRoot));
  return Array.from(new Set(selected));
}

function readPrivateWorkflowRegistries(extraRoot, noDefaultRoots) {
  const registries = [];
  for (const root of registryRoots(extraRoot, noDefaultRoots)) {
    if (!fs.existsSync(root)) continue;
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const file = path.join(root, entry.name, 'workflow-registry.json');
      if (!fs.existsSync(file)) continue;
      const data = readJson(file);
      if (!data || data.__error) {
        registries.push({ source: file, status: 'invalid', error: data ? data.__error : 'missing registry' });
      } else {
        registries.push({ source: file, status: 'ok', data });
      }
    }
  }
  return registries;
}

function normalizeStage(raw, defaultOwnerModule) {
  return {
    stage_id: String(raw.stage_id || ''),
    label: String(raw.label || raw.stage_id || ''),
    description: String(raw.description || ''),
    frontend_surface: String(raw.frontend_surface || ''),
    owner_module: String(raw.owner_module || defaultOwnerModule || ''),
    required_inputs: Array.isArray(raw.required_inputs) ? raw.required_inputs.slice() : [],
    completion_conditions: Array.isArray(raw.completion_conditions) && raw.completion_conditions.length > 0
      ? raw.completion_conditions.slice()
      : [`${raw.stage_id}.completed`],
    allowed_next: Array.isArray(raw.allowed_next) ? raw.allowed_next.slice() : [],
    requires_user_confirm: Boolean(raw.requires_user_confirm),
    risk_level: String(raw.risk_level || 'medium'),
    ...(raw.memory_contract && typeof raw.memory_contract === 'object'
      ? { memory_contract: cloneJson(raw.memory_contract) }
      : {}),
    ...(raw.transition_contract && typeof raw.transition_contract === 'object'
      ? { transition_contract: cloneJson(raw.transition_contract) }
      : {}),
    ...(raw.interaction_contract && typeof raw.interaction_contract === 'object'
      ? { interaction_contract: cloneJson(raw.interaction_contract) }
      : {}),
  };
}

function applyWorkflowOverride(allTemplates, item, source) {
  const workflowType = String(item.workflow_type || '');
  if (!workflowType || !allTemplates[workflowType]) return;
  const ownerModule = String(item.owner_module || '');
  const stageOwnerOverrides = item.stage_owner_overrides && typeof item.stage_owner_overrides === 'object'
    ? item.stage_owner_overrides
    : {};
  if (ownerModule) {
    for (const stageDef of allTemplates[workflowType].stages) stageDef.owner_module = ownerModule;
  }
  for (const stageDef of allTemplates[workflowType].stages) {
    if (stageOwnerOverrides[stageDef.stage_id]) stageDef.owner_module = String(stageOwnerOverrides[stageDef.stage_id]);
  }
  allTemplates[workflowType].private_overlay = {
    source,
    module: String(item.module || ownerModule || ''),
    reason: String(item.reason || ''),
  };
}

function applyWorkflowTemplate(allTemplates, item, source) {
  const workflowType = String(item.workflow_type || '');
  const stages = Array.isArray(item.stages) ? item.stages : [];
  if (!workflowType || stages.length === 0) return;
  const baseWorkflowType = String(item.extends_workflow_type || '');
  const baseTemplate = baseWorkflowType && allTemplates[baseWorkflowType]
    ? cloneJson(allTemplates[baseWorkflowType])
    : null;
  const coverage = baseTemplate
    ? validateWorkflowExtensionCoverage({
      baseTemplate,
      extensionStages: stages,
      stageEquivalences: item.stage_equivalences,
    })
    : null;
  if (coverage && coverage.status !== 'covered') {
    throw new Error(`${workflowType} private workflow misses public stages: ${coverage.missing_base_stages.join(', ')}`);
  }
  const baseStages = new Map(((baseTemplate || {}).stages || []).map((stageDef) => [stageDef.stage_id, stageDef]));
  const defaultOwner = String(item.owner_module || '');
  const unitLifecycleContract = extensionUnitLifecycleContract(item, baseTemplate, stages);
  allTemplates[workflowType] = ensureTemplateMemoryContracts({
    workflow_type: workflowType,
    default_completion_policy: String(item.default_completion_policy || (baseTemplate || {}).default_completion_policy || 'stage_then_confirm'),
    safe_full_auto: item.safe_full_auto === undefined ? Boolean((baseTemplate || {}).safe_full_auto) : Boolean(item.safe_full_auto),
    unit_lifecycle_contract: unitLifecycleContract,
    result_contract: item.result_contract || (baseTemplate || {}).result_contract || resultContractV2(),
    recovery: item.recovery || (baseTemplate || {}).recovery || recoveryContract(),
    production_kernel: String(item.production_kernel || ((baseTemplate || {}).production_kernel) || ''),
    stages: stages.map((stageDef) => {
      const merged = { ...(baseStages.get(stageDef.stage_id) || {}), ...stageDef };
      // A private enhancement owns every stage it redeclares unless that
      // stage explicitly delegates to another module. Keeping the base
      // owner's value here silently routed private production stages back to
      // the public short-writing module after an update.
      if (!Object.prototype.hasOwnProperty.call(stageDef, 'owner_module') && defaultOwner) {
        merged.owner_module = defaultOwner;
      }
      return normalizeStage(merged, defaultOwner);
    }),
    private_overlay: {
      source,
      module: String(item.module || defaultOwner || ''),
      reason: String(item.reason || ''),
      mode: baseTemplate ? 'enhance' : 'replace',
      base_workflow_type: baseTemplate ? baseWorkflowType : '',
      baseline_coverage: coverage,
    },
  });
}

function extensionUnitLifecycleContract(item, baseTemplate, extensionStages) {
  if (item.unit_lifecycle_contract) return cloneJson(item.unit_lifecycle_contract);
  const base = cloneJson((baseTemplate || {}).unit_lifecycle_contract || unitLifecycle(String(item.unit_type || 'workflow_batch'), {}));
  const roles = { ...((base || {}).stage_roles || {}) };
  const equivalences = item.stage_equivalences && typeof item.stage_equivalences === 'object' ? item.stage_equivalences : {};
  for (const [baseStageId, extensionIds] of Object.entries(equivalences)) {
    const role = String(roles[baseStageId] || '');
    if (!role) continue;
    for (const extensionId of Array.isArray(extensionIds) ? extensionIds : []) roles[String(extensionId)] = role;
  }
  const overrides = item.stage_role_overrides && typeof item.stage_role_overrides === 'object' ? item.stage_role_overrides : {};
  for (const [stageId, role] of Object.entries(overrides)) roles[String(stageId)] = String(role);
  for (const stageDef of extensionStages || []) {
    const stageId = String((stageDef || {}).stage_id || '');
    if (stageId && !roles[stageId]) roles[stageId] = inferredExtensionStageRole(stageId);
  }
  return { ...base, stage_roles: roles };
}

function inferredExtensionStageRole(stageId) {
  const id = String(stageId || '');
  if (/^(startup_scan|startup_menu)$/.test(id)) return 'workflow_preflight';
  if (/source|material|learning|freshness|seed/.test(id)) return 'source_or_material';
  if (/brief|setting|genre|rhythm|outline|plan_lock|feedback_apply/.test(id)) return 'brief_or_contract';
  if (/machine/.test(id)) return 'machine_quality_gate';
  if (/draft|repair/.test(id)) return 'draft_or_execute';
  if (/accept|assembly/.test(id)) return 'state_integration';
  if (/final|closure/.test(id)) return 'handoff_and_next';
  if (/review|quality|hook|compare|impact/.test(id)) return 'quality_gate';
  return 'review_or_validate';
}

function validateWorkflowExtensionCoverage({ baseTemplate = {}, extensionStages = [], stageEquivalences = {} } = {}) {
  const extensionIds = new Set((extensionStages || []).map((stageDef) => String((stageDef || {}).stage_id || '')).filter(Boolean));
  const mappings = stageEquivalences && typeof stageEquivalences === 'object' ? stageEquivalences : {};
  const missing = [];
  const coveredBy = {};
  for (const baseStage of (baseTemplate.stages || [])) {
    const baseId = String((baseStage || {}).stage_id || '');
    if (!baseId) continue;
    if (extensionIds.has(baseId)) {
      coveredBy[baseId] = [baseId];
      continue;
    }
    const mapped = Array.isArray(mappings[baseId]) ? mappings[baseId].map(String) : [String(mappings[baseId] || '')].filter(Boolean);
    const validMapped = mapped.filter((stageId) => extensionIds.has(stageId));
    if (!mapped.length || validMapped.length !== mapped.length) missing.push(baseId);
    else coveredBy[baseId] = validMapped;
  }
  return {
    status: missing.length ? 'missing_public_capability' : 'covered',
    missing_base_stages: missing,
    covered_by: coveredBy,
  };
}

function applyWorkflowAlias(allTemplates, item, source) {
  const workflowType = String(item.workflow_type || '');
  const targetWorkflowType = String(item.target_workflow_type || '');
  if (!workflowType || !targetWorkflowType || !allTemplates[targetWorkflowType]) return;
  allTemplates[workflowType] = {
    ...cloneJson(allTemplates[targetWorkflowType]),
    workflow_type: workflowType,
    legacy_alias_of: targetWorkflowType,
    migration_only: item.migration_only !== false,
    private_overlay: {
      ...((allTemplates[targetWorkflowType] || {}).private_overlay || {}),
      source,
      module: String(item.module || ((allTemplates[targetWorkflowType] || {}).private_overlay || {}).module || ''),
      reason: String(item.reason || `legacy alias of ${targetWorkflowType}`),
    },
  };
}

function buildEffectiveTemplates(extraRoot, noDefaultRoots) {
  const allTemplates = cloneJson(BASE_TEMPLATES);
  const registries = readPrivateWorkflowRegistries(extraRoot, noDefaultRoots);
  for (const registry of registries) {
    if (registry.status !== 'ok') continue;
    const data = registry.data || {};
    const moduleName = String(data.module || '');
    for (const item of data.workflow_overrides || []) applyWorkflowOverride(allTemplates, { module: moduleName, ...item }, registry.source);
    for (const item of data.workflow_templates || []) applyWorkflowTemplate(allTemplates, { module: moduleName, ...item }, registry.source);
    for (const item of data.workflow_aliases || []) applyWorkflowAlias(allTemplates, { module: moduleName, ...item }, registry.source);
  }
  for (const templateDef of Object.values(allTemplates)) ensureTemplateMemoryContracts(templateDef);
  return { templates: allTemplates, registries };
}

// Resolve whether the currently-loaded template registry still satisfies the
// workflow identity recorded on a task snapshot. This is the authority gate
// that prevents a private short_write task from silently degrading to the
// public short_write template when the private registry is unavailable
// (book moved, different host without the private package, --no-private-registry).
//
// Identity binding uses owner_module (stable across reasonable registry edits).
// registry_id / registry_digest are recorded for audit but not enforced, so
// routine content updates inside the same module do not become hard blockers.
//
// Legacy tasks without workflow_registry are safely back-filled from
// workflow_profile + workflow_owner; cwd is never consulted to guess owner.
function resolveTemplateForTask(task, options = {}) {
  const effective = options.templates
    ? { templates: options.templates, registries: options.registries || [] }
    : buildEffectiveTemplates(options.privateRegistryRoot, false);
  const workflowType = String((task && task.workflow_type) || '');
  const expected = (task && task.workflow_registry) || {};
  const inferredPrivateAlias = !String(expected.profile || (task && task.workflow_profile) || '')
    && /^private_/u.test(workflowType)
    && Boolean((((effective.templates[workflowType] || {}).private_overlay) || {}).module);
  const expectedProfile = String(expected.profile || (task && task.workflow_profile) || (inferredPrivateAlias ? 'private' : 'public'));
  const expectedOwner = String(expected.owner_module || (task && task.workflow_owner) || '');
  // A public task stays public even when the current host also has a private
  // enhancement installed. Otherwise moving the same book between hosts can
  // silently replace its stage graph during resume.
  const template = expectedProfile === 'public'
    ? (BASE_TEMPLATES[workflowType] || null)
    : (effective.templates[workflowType] || null);
  const registry = {
    ...expected,
    profile: expectedProfile,
    owner_module: expectedOwner,
  };
  if (expectedProfile === 'private') {
    const overlayModule = String(((template && template.private_overlay) || {}).module || '');
    if (!template || !template.private_overlay || (expectedOwner && overlayModule !== expectedOwner)) {
      return {
        status: 'blocked_private_workflow_registry_unavailable',
        template: null,
        registry,
        owner_module: expectedOwner,
        workflow_type: workflowType,
      };
    }
  }
  return {
    status: 'ok',
    template,
    registry,
    owner_module: expectedOwner,
    workflow_type: workflowType,
  };
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

module.exports = {
  BASE_TEMPLATES,
  LONG_WRITE_RESULT_FIELDS,
  RESULT_CONTRACT_V2_FIELDS,
  buildEffectiveTemplates,
  ensureTemplateMemoryContracts,
  resolveTemplateForTask,
  stageMemoryContract,
  validateWorkflowExtensionCoverage,
  unitLifecycle,
};
