#!/usr/bin/env node
'use strict';

const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const USAGE = `Usage: node scripts/production-smoke-matrix.js [--repo-root <dir>] [--json]
       node scripts/production-smoke-matrix.js --route-reference <user-intent> [--bundle] [--json]

Runs deterministic production smoke checks for novel-assistant skill routing:
short writing, long writing, review, analyze, scans, cover, deslop, setup, and update check.
It does not call a model and does not modify book projects.`;

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const routeReferenceIntent = readOption('--route-reference');
const routeReferenceLayer = args.includes('--bundle') ? 'bundle' : 'source';
const repoRoot = path.resolve(readOption('--repo-root') || path.join(__dirname, '..'));
const WORKFLOW_ENTRY = 'src/internal-skills/story-workflow/SKILL.md';
const WORKFLOW_REFERENCES = 'src/internal-skills/story-workflow/references';
const ENTRY_RUNTIME = 'skills/novel-assistant/references/entry-runtime-contract.md';
const ROUTER_EDGE_CASES = 'src/internal-skills/story/references/router-edge-cases.md';

// Task 10 keeps the entry small: every heavy smoke anchor remains mandatory,
// but is checked in the protocol that the entry explicitly indexes.
const PROGRESSIVE_WORKFLOW_ANCHORS = Object.freeze({
  '短篇写作': 'canonical-write-protocol.md',
  short_story_style_pack: 'canonical-write-protocol.md',
  genre_style_pack: 'canonical-write-protocol.md',
  short_format_path: 'canonical-write-protocol.md',
  short_deslop_path: 'canonical-write-protocol.md',
  '短篇不套长篇 Chapter Contract': 'canonical-write-protocol.md',
  '长篇写作': 'runner-execution-protocol.md',
  'story-long-write': 'task-inbox-protocol.md',
  expansion_transaction: 'task-inbox-protocol.md',
  'story-expansion-plan.js': 'task-inbox-protocol.md',
  accepted_commit_id: 'completion-evidence-protocol.md',
  '审阅与修复': 'completion-evidence-protocol.md',
  '非连续范围': 'completion-evidence-protocol.md',
  gap: 'completion-evidence-protocol.md',
  '长篇拆文': 'completion-evidence-protocol.md',
  'source-grounding': 'completion-evidence-protocol.md',
  full_auto: 'completion-evidence-protocol.md',
  '拆文全量推进': 'task-inbox-protocol.md',
  long_scan: 'completion-evidence-protocol.md',
  '市场趋势与扫榜': 'completion-evidence-protocol.md',
  source_lock: 'completion-evidence-protocol.md',
  trend_validation: 'completion-evidence-protocol.md',
  short_scan: 'completion-evidence-protocol.md',
  short_analyze: 'completion-evidence-protocol.md',
  analysis_execute: 'completion-evidence-protocol.md',
  source_validation: 'completion-evidence-protocol.md',
  memory_updates: 'completion-evidence-protocol.md',
  cover: 'completion-evidence-protocol.md',
  generation_confirmation: 'completion-evidence-protocol.md',
  generate_cover_execute: 'completion-evidence-protocol.md',
  '覆盖任何现有封面前': 'completion-evidence-protocol.md',
  '去 AI 味': 'completion-evidence-protocol.md',
  'story-deslop': 'completion-evidence-protocol.md',
  '短篇去 AI 味优先用': 'completion-evidence-protocol.md',
  'current-task.json': 'task-inbox-protocol.md',
  pending_action: 'task-inbox-protocol.md',
  'workflow-runtime-supervisor.js': 'completion-evidence-protocol.md',
  '数字候选协议': 'task-inbox-protocol.md',
  '不要同时展示 `A/B/C/D`': 'task-inbox-protocol.md',
  free_text_enabled: 'task-inbox-protocol.md',
  '输入其他意见': 'task-inbox-protocol.md',
  'host_select 优先、text_numbers 兜底': 'task-inbox-protocol.md',
  interaction_renderer: 'task-inbox-protocol.md',
  '"render_mode": "text_numbers"': 'task-inbox-protocol.md',
  '"fallback": "text_numbers"': 'task-inbox-protocol.md',
  host_select_failed: 'task-inbox-protocol.md',
  interaction_degraded_to_text_numbers: 'task-inbox-protocol.md',
  '上下方向键': 'task-inbox-protocol.md',
  token_cost_governance: 'runner-execution-protocol.md',
  cost_ledger_path: 'runner-execution-protocol.md',
  model_routing_policy: 'runner-execution-protocol.md',
  tool_output_filter: 'runner-execution-protocol.md',
  '节点完成成本摘要': 'runner-execution-protocol.md',
  '异常浪费必须主动提醒': 'runner-execution-protocol.md',
  '主动/被动成本提醒协议': 'runner-execution-protocol.md',
  '节省 token 执行协议': 'runner-execution-protocol.md',
  '全局任务收件箱': 'task-inbox-protocol.md',
  'workflow-task-inbox.js': 'task-inbox-protocol.md',
  workflow_groups: 'task-inbox-protocol.md',
  post_completion_recommendations: 'task-inbox-protocol.md',
  'task-index.json': 'task-inbox-protocol.md',
  metadata_only: 'task-inbox-protocol.md',
  'workflow-state-machine.js': 'task-inbox-protocol.md',
  'state machine': 'task-inbox-protocol.md',
  remaining_stages: 'task-inbox-protocol.md',
  'AI Native 小说生产吸收契约': 'task-inbox-protocol.md',
  'quality-debt-policy.md': 'quality-debt-policy.md',
  'structured-intent-routing.md': 'structured-intent-routing.md',
  'story-assets-ledger.md': 'story-assets-ledger.md',
  'style-asset-engine.md': 'style-asset-engine.md',
});
const PROGRESSIVE_ENTRY_ANCHORS = Object.freeze({
  '两层更新协议': 'entry-runtime-contract.md',
  'novel-assistant-update-check.js': 'entry-runtime-contract.md',
  'novel-assistant-self-update.js': 'entry-runtime-contract.md',
  '不得把 skill 更新和当前书籍项目的协作环境更新混为一步': 'entry-runtime-contract.md',
  '宿主选择器适配协议': 'entry-runtime-contract.md',
  'interaction_renderer=host_select_preferred': 'entry-runtime-contract.md',
  'render_mode=text_numbers': 'entry-runtime-contract.md',
  'fallback=text_numbers': 'entry-runtime-contract.md',
  '宿主支持时优先渲染 host_select': 'entry-runtime-contract.md',
  '不得直接调用原始 AskUserQuestion': 'entry-runtime-contract.md',
  'host_select_failed': 'entry-runtime-contract.md',
  '出现 `host_select_failed` 时退回数字文本': 'entry-runtime-contract.md',
});
const PROGRESSIVE_ROUTER_ANCHORS = Object.freeze({
  'Chapter Contract': 'router-edge-cases.md',
  '中文自然语言意图归一化': 'router-edge-cases.md',
  '不要先路由到长篇通用 story-deslop': 'router-edge-cases.md',
});
let workflowTemplateSummary = { sourceCount: 0, bundleCount: 0, drift: true };

if (args.includes('-h') || args.includes('--help')) {
  console.log(USAGE);
  process.exit(0);
}

const CASES = [
  {
    id: 'short_write',
    label: '短篇写作/短篇去 AI 味',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '短篇写作路由补充',
        '短篇/盐言/一万字/写个故事',
        '先读取 story-workflow',
        'story-short-write',
        'short_deslop_path',
        '不要先路由到长篇通用 story-deslop',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '短篇写作',
        'short_story_style_pack',
        'genre_style_pack',
        'short_format_path',
        'short_deslop_path',
        '短篇不套长篇 Chapter Contract',
      ]),
      check('module', 'src/internal-skills/story-short-write/SKILL.md', [
        '## L3 Workflow Contract',
        'Inputs From story-workflow',
        'Outputs To story-workflow',
        'short_format_path',
        'short_deslop_path',
        'Completion Conditions',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md', [
        '## L3 Workflow Contract',
        'short_deslop_path',
      ]),
    ],
  },
  {
    id: 'long_write',
    label: '长篇写作/续写/扩容',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '长篇稳定性默认策略',
        'Chapter Contract',
        'story-long-write',
        '扩容/插章/后移章节',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '长篇写作',
        'story-long-write',
        'expansion_transaction',
        'story-expansion-plan.js',
        'accepted_commit_id',
      ]),
      check('script', 'scripts/chapter-commit.js', []),
      check('module', 'src/internal-skills/story-long-write/SKILL.md', [
        '## L3 Workflow Contract',
        'Chapter Contract',
        'Drift Gate',
        'changed_files',
        'chapter title preservation',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md', [
        '## L3 Workflow Contract',
        'Chapter Contract',
      ]),
    ],
  },
  {
    id: 'long_write_detail_outline_quality',
    label: '长篇细纲可执行性与欠填阻断',
    checks: [
      check('runtime', 'scripts/detail-outline-quality-check.js', []),
      check('script', 'scripts/lib/detail-outline-quality.js', ['outline_underfilled']),
      check('script', 'scripts/lib/detail-outline-quality-projection.js', ['projectAcceptedQuality']),
      check('reference', 'src/internal-skills/story-long-write/references/detail-outline-quality-gate.md', [
        '基础门',
        '最小语义审阅',
        'outline_underfilled',
      ]),
      check('bundle', 'skills/novel-assistant/scripts/detail-outline-quality-check.js', []),
      check('bundle', 'skills/novel-assistant/scripts/lib/detail-outline-quality.js', ['outline_underfilled']),
      check('bundle', 'skills/novel-assistant/scripts/lib/detail-outline-quality-projection.js', ['projectAcceptedQuality']),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-long-write/references/detail-outline-quality-gate.md', [
        '基础门',
        '最小语义审阅',
        'outline_underfilled',
      ]),
    ],
    run() {
      runDetailOutlineQualityCase(repoRoot);
    },
  },
  {
    id: 'review',
    label: '范围审阅/补审/修复方案',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '全书/范围诊断',
        'story-review',
        '读 1-200 章',
        '中文自然语言意图归一化',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '审阅与修复',
        'story-review',
        '非连续范围',
        'gap',
      ]),
      check('module', 'src/internal-skills/story-review/SKILL.md', [
        '## L3 Workflow Contract',
        'unreviewed gaps',
        'review-state.json',
        'gap_reconciliation_required',
        'Findings Schema',
        '盲读者与误伤率校准',
        'blind-reader-protocol.md',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-review/SKILL.md', [
        '## L3 Workflow Contract',
        'review-state.json',
      ]),
    ],
  },
  {
    id: 'analyze',
    label: '长篇/短篇拆文',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '拆文请求',
        'story-workflow',
        'story-long-analyze',
        'story-short-analyze',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '长篇拆文',
        'source-grounding',
        'full_auto',
        '拆文全量推进',
      ]),
      check('module', 'src/internal-skills/story-long-analyze/SKILL.md', [
        '## L3 Workflow Contract',
        'source-grounding',
        'batch progress',
        'generated asset paths',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md', [
        '## L3 Workflow Contract',
        'source-grounding',
      ]),
    ],
  },
  {
    id: 'long_scan',
    label: '长篇扫榜/选题趋势',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '长篇扫榜工作流',
        'long_scan',
        'story-long-scan',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'long_scan',
        '市场趋势与扫榜',
        'source_lock',
        'trend_validation',
      ]),
      check('module', 'src/internal-skills/story-long-scan/SKILL.md', [
        'Phase 1：确认平台和方向',
        '数据质量',
        '选题决策',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-long-scan/SKILL.md', [
        'Phase 1：确认平台和方向',
        '选题决策',
      ]),
    ],
  },
  {
    id: 'short_scan',
    label: '短篇扫榜/情绪趋势',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '短篇扫榜工作流',
        'short_scan',
        'story-short-scan',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'short_scan',
        '市场趋势与扫榜',
        'source_lock',
        'trend_validation',
      ]),
      check('module', 'src/internal-skills/story-short-scan/SKILL.md', [
        'Phase 1：确认平台和方向',
        'source=wangwen_debut',
        '题材标签',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-short-scan/SKILL.md', [
        'Phase 1：确认平台和方向',
        'source=wangwen_debut',
      ]),
    ],
  },
  {
    id: 'short_analyze',
    label: '短篇拆文/结构吸收',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '短篇拆文工作流',
        'short_analyze',
        'story-short-analyze',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'short_analyze',
        'analysis_execute',
        'source_validation',
        'memory_updates',
      ]),
      check('module', 'src/internal-skills/story-short-analyze/SKILL.md', [
        'Phase 1：确认拆解对象',
        'memory_updates',
        '不得把拆文原作',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-short-analyze/SKILL.md', [
        'Phase 1：确认拆解对象',
        'memory_updates',
      ]),
    ],
  },
  {
    id: 'cover',
    label: '书籍封面/确认式出图',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '封面工作流',
        'cover',
        'story-cover',
        '生成或覆盖前确认',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'cover',
        'generation_confirmation',
        'generate_cover_execute',
        '覆盖任何现有封面前',
      ]),
      check('module', 'src/internal-skills/story-cover/SKILL.md', [
        'Step 1：收集信息',
        'Step 3：调用 API 并保存',
        '自增版本号，避免覆盖之前生成的封面',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-cover/SKILL.md', [
        'Step 1：收集信息',
        '自增版本号，避免覆盖之前生成的封面',
      ]),
    ],
  },
  {
    id: 'deslop',
    label: '去 AI 味/正文洁净',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '去 AI 味请求',
        'story-deslop',
        '短篇去 AI 味',
        'short-deslop.md',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '去 AI 味',
        'story-deslop',
        '短篇去 AI 味优先用',
      ]),
      check('module', 'src/internal-skills/story-deslop/SKILL.md', [
        '## L3 Workflow Contract',
        'prose-only',
        'fact preservation',
        'AI-pattern scan',
        '盲读者与误伤率校准',
        'falsePositiveRate',
      ]),
      check('script', 'scripts/prose-quality-benchmark.js', [
        '--blind-packet',
        'falsePositiveRate',
        'falseNegativeRate',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-deslop/SKILL.md', [
        '## L3 Workflow Contract',
        'prose-only',
      ]),
    ],
    run() {
      runProseQualityCalibrationCase(repoRoot);
    },
  },
  {
    id: 'setup',
    label: 'setup/协作环境更新/迁移门禁',
    checks: [
      check('router', 'src/internal-skills/story/SKILL.md', [
        '更新确认优先于工作流编排',
        'story-setup',
        '更新写作协作环境',
        '不得读取章节状态',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'current-task.json',
        'pending_action',
        'workflow-runtime-supervisor.js',
      ]),
      check('module', 'src/internal-skills/story-setup/SKILL.md', [
        '更新写作协作环境',
        '不移动正文、大纲、细纲',
        '迁移章节结构',
        'story-project-migrate.js',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-setup/SKILL.md', [
        '更新写作协作环境',
        '迁移章节结构',
      ]),
    ],
  },
  {
    id: 'update_check',
    label: 'skill 更新检查/两层更新协议',
    checks: [
      check('router', 'skills/novel-assistant/SKILL.md', [
        '两层更新协议',
        'novel-assistant-update-check.js',
        'novel-assistant-self-update.js',
        '不得把 skill 更新和当前书籍项目的协作环境更新混为一步',
      ]),
      check('workflow', 'src/internal-skills/story/SKILL.md', [
        '更新维护',
        '检查更新',
        '更新 skill',
        '更新写作协作环境',
      ]),
      check('module', 'src/internal-skills/story-setup/SKILL.md', [
        'novel-assistant-update-check.js',
        '更新写作协作环境',
        '部署验证',
      ]),
      check('bundle', 'skills/novel-assistant/scripts/novel-assistant-update-check.js', []),
      check('bundle', 'skills/novel-assistant/scripts/novel-assistant-self-update.js', []),
      check('bundle', 'skills/novel-assistant/scripts/production-smoke-matrix.js', []),
    ],
  },
  {
    id: 'story_memory_context',
    label: '创作记忆库上下文装配',
    checks: [
      check('script', 'scripts/context-assembler.js', []),
      check('script', 'scripts/memory-recommender.js', []),
      check('script', 'scripts/memory-migrate.js', []),
      check('workflow', 'src/internal-skills/story-workflow/references/story-memory-context.md', [
        '创作记忆库',
        'memory-suggestions.jsonl',
        'blocked_output_pollution',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/story-memory-context.md', []),
    ],
    run() {
      runStoryMemoryContextCase(repoRoot);
    },
  },
  {
    id: 'longform_lifecycle_new_book',
    label: '新书分层生命周期与逐层审阅',
    checks: [
      check('workflow', 'src/internal-skills/story-workflow/references/completion-evidence-protocol.md', [
        'positioning -> story_bible -> master_outline -> master_outline_review -> volume_outline -> volume_outline_review -> stage_detail_outline -> detail_outline_review -> chapter_brief -> brief_review -> prose',
      ]),
      check('script', 'scripts/lib/longform-lifecycle.js', ['master_outline_review', 'brief_review', 'milestone_review']),
      check('bundle', 'skills/novel-assistant/scripts/lib/longform-lifecycle.js', ['master_outline_review', 'brief_review', 'milestone_review']),
    ],
  },
  {
    id: 'longform_lifecycle_existing_book',
    label: '已有书成熟度恢复与自然下一步',
    checks: [
      check('script', 'scripts/longform-lifecycle-status.js', ['recommended_actions', 'blocking_gaps']),
      check('script', 'scripts/workflow-task-inbox.js', ['longform_lifecycle_next']),
      check('bundle', 'skills/novel-assistant/scripts/longform-lifecycle-status.js', ['recommended_actions', 'blocking_gaps']),
    ],
  },
  {
    id: 'longform_volume_review',
    label: '卷级审阅与内部动态取证',
    checks: [
      check('module', 'src/internal-skills/story-review/SKILL.md', ['review_target.visible_label', '禁止展示内部批次 ID']),
      check('script', 'scripts/lib/review-target-policy.js', ['user_visible_batches: false', "'volume'"]),
      check('bundle', 'skills/novel-assistant/scripts/lib/review-target-policy.js', ['user_visible_batches: false', "'volume'"]),
    ],
  },
  {
    id: 'longform_feedback_rollback',
    label: '反馈影响分级与安全回退',
    checks: [
      check('module', 'src/internal-skills/story-long-write/references/workflow-review-feedback.md', ['preserve_until_proven_invalid']),
      check('script', 'scripts/lib/lifecycle-impact.js', ['return_to', 'preserve_until_proven_invalid']),
      check('bundle', 'skills/novel-assistant/scripts/lib/lifecycle-impact.js', ['return_to', 'preserve_until_proven_invalid']),
    ],
  },
  {
    id: 'longform_structure_expansion',
    label: '结构扩容影响分析与位移事务',
    checks: [
      check('script', 'scripts/story-expansion-plan.js', []),
      check('module', 'src/internal-skills/story-long-write/references/revision-impact-analysis.md', ['preserve_until_proven_invalid']),
      check('bundle', 'skills/novel-assistant/scripts/story-expansion-plan.js', []),
    ],
  },
  {
    id: 'longform_cross_volume_handoff',
    label: '跨卷交接与连续性审计',
    checks: [
      check('script', 'scripts/cross-volume-handoff-pack.sh', ['cross-volume-continuity-audit.sh']),
      check('module', 'src/internal-skills/story-long-write/SKILL.md', ['Cross Volume Handoff / Audit']),
      check('bundle', 'skills/novel-assistant/scripts/cross-volume-handoff-pack.sh', ['cross-volume-continuity-audit.sh']),
    ],
  },
  {
    id: 'longform_lifecycle_migration',
    label: '受支持旧项目生命周期迁移预演',
    checks: [
      check('script', 'scripts/workflow-legacy-migrate.js', []),
      check('bundle', 'skills/novel-assistant/scripts/workflow-legacy-migrate.js', []),
    ],
    run() {
      runLongformLifecycleMigrationCase(repoRoot);
    },
  },
  {
    id: 'short_writing_profile',
    label: '短篇平台与单题材方法选择',
    checks: [
      check('script', 'scripts/short-writing-profile.js', ['selectProfile', 'genre-writing-formulas.md']),
      check('reference', 'src/internal-skills/story-short-write/references/submission-profile.md', ['evidence_source', 'confidence', '一次只加载一个平台配置和一张题材卡']),
      check('bundle', 'skills/novel-assistant/scripts/short-writing-profile.js', ['selectProfile']),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-short-write/references/submission-profile.md', ['evidence_source', 'confidence']),
    ],
  },
  {
    id: 'host_discovery',
    label: 'Claude/Codex/ZCode/OpenCode/OpenClaw 只读发现',
    checks: [
      check('script', 'scripts/check-host-skill-discovery.js', ['static_read_only', 'symlink_not_allowed', 'mutations']),
      check('bundle', 'skills/novel-assistant/scripts/check-host-skill-discovery.js', ['static_read_only', 'symlink_not_allowed', 'mutations']),
    ],
  },
];

const GLOBAL_CHECKS = [
  {
    id: 'internal_skills_bundle_mirror',
    label: 'source internal-skills 与 bundle 镜像一致',
    checks: [],
    run() {
      assertDirectoryMirror(
        path.join(repoRoot, 'src', 'internal-skills'),
        path.join(repoRoot, 'skills', 'novel-assistant', 'references', 'internal-skills'),
      );
    },
  },
  {
    id: 'router_edge_reference_routes',
    label: 'router 边界意图按需加载契约',
    checks: [],
    run() {
      assertRouterEdgeReferenceRoutes(repoRoot);
    },
  },
  {
    id: 'task11_behavior_contract',
    label: 'Task 11 长篇写作与反迎合行为契约',
    checks: [],
    run() {
      runTask11BehaviorContractCase(repoRoot);
    },
  },
  {
    id: 'single_entry_ux',
    label: '单入口与用户命令简化',
    checks: [
      check('entry', 'skills/novel-assistant/SKILL.md', [
        '用户只需要记住当前顶层安装名',
        '/novel-assistant',
        '不要要求用户单独安装',
        '原来的 `story-*` 能力被打包为内部模块',
      ]),
      check('router', 'src/internal-skills/story/SKILL.md', [
        '对外输出命令规范',
        '统一只写 `/novel-assistant + 意图短语`',
        '不要把 `/story-long-write`',
        '单目录 `novel-assistant` 安装模式',
      ]),
    ],
  },
  {
    id: 'numbered_candidates_ux',
    label: '数字候选与自由输入出口',
    checks: [
      check('entry', 'skills/novel-assistant/SKILL.md', [
        'references/internal-skills/story-workflow/SKILL.md',
        '完整的 task inbox、短回复、数字候选、状态机与恢复规则',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '数字候选协议',
        '不要同时展示 `A/B/C/D`',
        'free_text_enabled',
        '输入其他意见',
      ]),
    ],
  },
  {
    id: 'host_select_ux',
    label: '上下键选择器优先与数字兜底',
    checks: [
      check('entry', 'skills/novel-assistant/SKILL.md', [
        '宿主选择器适配协议',
        'interaction_renderer=host_select_preferred',
        'render_mode=text_numbers',
        'fallback=text_numbers',
        '宿主支持时优先渲染 host_select',
        '不得直接调用原始 AskUserQuestion',
        'host_select_failed',
        '出现 `host_select_failed` 时退回数字文本',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'host_select 优先、text_numbers 兜底',
        'interaction_renderer',
        '"render_mode": "text_numbers"',
        '"fallback": "text_numbers"',
        'host_select_failed',
        'interaction_degraded_to_text_numbers',
        '上下方向键',
      ]),
    ],
  },
  {
    id: 'update_gate_ux',
    label: '更新确认不混入业务候选',
    checks: [
      check('entry', 'skills/novel-assistant/SKILL.md', [
        '更新确认是硬前置门禁',
        '第一屏只能是更新确认',
        '不得同时输出更新确认和写作意图候选',
        '确认更新或暂不更新后，才允许读取项目状态并判断写作意图',
      ]),
      check('router', 'src/internal-skills/story/SKILL.md', [
        '更新确认优先于工作流编排',
        '第一屏只能展示协作环境更新确认',
        '不得读取章节状态、当前进度或业务候选',
        '暂不更新后，才恢复原始写作意图路由',
      ]),
    ],
  },
  {
    id: 'maintainability_kernel',
    label: 'skill 维护性内核与审计',
    checks: [
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'maintainability-kernel.md',
        'workflow-contract.md',
        'output-safety-contract.md',
      ]),
      check('script', 'scripts/maintainability-audit.js', [
        'maintainability-audit.js',
        'workflow-contract.md',
        'output-safety-contract.md',
      ]),
      check('docs', 'docs/production-readiness.md', [
        'maintainability-audit.js',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/workflow-contract.md', []),
    ],
  },
  {
    id: 'token_cost_governance',
    label: 'Token 成本治理与可见账本',
    checks: [
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'token_cost_governance',
        'cost_ledger_path',
        'model_routing_policy',
        'tool_output_filter',
        '节点完成成本摘要',
        '异常浪费必须主动提醒',
        '主动/被动成本提醒协议',
        '节省 token 执行协议',
      ]),
      check('script', 'scripts/runtime-guard-validate.js', [
        'blocked_token_cost_governance_missing',
        'runtime_guard.token_cost_governance',
      ]),
      check('script', 'scripts/workflow-runtime-supervisor.js', [
        'cost_summary_path',
        'cost_summary_status',
        'cost_alerts',
        'should_notify_user',
        'token_saving_plan',
        'passive_cost_report_available',
      ]),
      check('script', 'scripts/token-cost-ledger.js', [
        'Token Cost Summary',
        'waste_signals',
        'proactive_alerts',
        'token_saving_plan',
      ]),
      check('module', 'src/internal-skills/story-setup/SKILL.md', [
        'token-cost-ledger.js',
        'token_cost_governance',
      ]),
      check('bundle', 'skills/novel-assistant/scripts/token-cost-ledger.js', []),
      check('bundle', 'skills/novel-assistant/scripts/runtime-guard-validate.js', [
        'blocked_token_cost_governance_missing',
      ]),
    ],
  },
  {
    id: 'workflow_task_inbox',
    label: '全局任务收件箱',
    checks: [
      check('entry', 'skills/novel-assistant/SKILL.md', [
        'workflow-task-inbox.js',
        '任务收件箱总览',
        '查看未完成任务',
        'task_cards[]',
      ]),
      check('router', 'src/internal-skills/story/SKILL.md', [
        '全局任务收件箱',
        'workflow-task-inbox.js',
        'workflow_groups',
        'task-index.json',
      ]),
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        '全局任务收件箱',
        'workflow-task-inbox.js',
        'workflow_groups',
        'post_completion_recommendations',
        'task-index.json',
        'metadata_only',
      ]),
      check('bundle', 'skills/novel-assistant/scripts/workflow-task-inbox.js', []),
    ],
  },
  {
    id: 'workflow_state_machine',
    label: 'Workflow 状态机与阶段裁决',
    checks: [
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'workflow-state-machine.js',
        'state machine',
        'pending_action',
        'remaining_stages',
      ]),
      check('script', 'scripts/workflow-state-machine.js', []),
      check('script', 'scripts/workflow-runner.js', [
        'status',
        'once',
        'run',
        'adapter_required',
        'needs_confirmation',
      ]),
      check('script', 'scripts/workflow-supervisor.js', [
        'once',
        'watch',
        'stopped_needs_confirmation',
        'max-total-budget-usd',
      ]),
      check('script', 'scripts/lib/workflow-host-adapters.js', [
        'claude-code',
        'codex',
        'zcode',
        'shell: false',
      ]),
      check('script', 'scripts/lib/workflow-stream-health.js', [
        'model_degradation_repeated_term',
        'tool_failure_loop',
        'provider_failure_loop',
      ]),
      check('script', 'scripts/workflow-state-validate.js', []),
      check('script', 'scripts/workflow-recover.js', []),
      check('script', 'scripts/workflow-review-batches.js', []),
      check('bundle', 'skills/novel-assistant/scripts/workflow-state-machine.js', []),
      check('bundle', 'skills/novel-assistant/scripts/workflow-runner.js', []),
      check('bundle', 'skills/novel-assistant/scripts/workflow-supervisor.js', []),
      check('bundle', 'skills/novel-assistant/scripts/workflow-recover.js', []),
    ],
    run() {
      runWorkflowTemplateCase(repoRoot);
    },
  },
  {
    id: 'AI_native_absorption',
    label: 'AI Native 小说生产吸收契约',
    checks: [
      check('workflow', 'src/internal-skills/story-workflow/SKILL.md', [
        'AI Native 小说生产吸收契约',
        'quality-debt-policy.md',
        'structured-intent-routing.md',
        'story-assets-ledger.md',
        'style-asset-engine.md',
      ]),
      check('router', 'src/internal-skills/story/SKILL.md', [
        'AI-first structured intent',
        'intent_schema',
        'route_confidence',
        'fallback_question',
      ]),
      check('contract', 'src/internal-skills/story-workflow/references/workflow-contract.md', [
        'quality_debt',
        'confirmed_facts',
        'pending_cast_candidates',
        'style_feature_pool',
      ]),
      check('docs', 'docs/reference-project-watch-sop.md', [
        'AI-Novel-Writing-Assistant',
        '质量债务',
        '角色资源账本',
        '写法资产',
      ]),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/quality-debt-policy.md', []),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/structured-intent-routing.md', []),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/story-assets-ledger.md', []),
      check('bundle', 'skills/novel-assistant/references/internal-skills/story-workflow/references/style-asset-engine.md', []),
    ],
  },
];

function readOption(name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  if (index >= 0) return args[index + 1] || '';
  return '';
}

function check(layer, target, requiredText) {
  return { layer, target, requiredText };
}

function runCheck(caseId, spec) {
  const abs = path.join(repoRoot, spec.target);
  const findings = [];
  let content = '';

  if (!fs.existsSync(abs)) {
    findings.push(finding(caseId, spec.layer, spec.target, '<file>', 'required file is missing'));
    return { ...spec, status: 'fail', findings };
  }

  if (spec.requiredText.length === 0) {
    return { ...spec, status: 'pass', findings };
  }

  try {
    content = fs.readFileSync(abs, 'utf8');
  } catch (error) {
    findings.push(finding(caseId, spec.layer, spec.target, '<read>', error.message));
    return { ...spec, status: 'fail', findings };
  }

  for (const text of spec.requiredText) {
    const reference = progressiveReference(spec.target, text);
    if (!reference && content.includes(text)) continue;
    if (!reference) {
      findings.push(finding(caseId, spec.layer, spec.target, text, 'required smoke anchor is missing'));
      continue;
    }

    if (!content.includes(reference)) {
      findings.push(finding(caseId, 'workflow_entry', spec.target, reference, 'required progressive reference is missing from entry'));
      continue;
    }

    const referenceTarget = progressiveReferenceTarget(spec.target, reference);
    const referencePath = path.join(repoRoot, referenceTarget);
    let referenceContent = '';
    try {
      referenceContent = fs.readFileSync(referencePath, 'utf8');
    } catch (error) {
      findings.push(finding(caseId, 'workflow_reference', referenceTarget, '<read>', error.message));
      continue;
    }

    if (reference === text && referenceContent.trim()) continue;
    if (!referenceContent.includes(text)) {
      findings.push(finding(caseId, 'workflow_reference', referenceTarget, text, 'required smoke anchor is missing'));
    }
  }

  return { ...spec, status: findings.length ? 'fail' : 'pass', findings };
}

function progressiveReference(target, text) {
  if (target === WORKFLOW_ENTRY) return PROGRESSIVE_WORKFLOW_ANCHORS[text] || null;
  if (target === 'skills/novel-assistant/SKILL.md') return PROGRESSIVE_ENTRY_ANCHORS[text] || null;
  if (target === 'src/internal-skills/story/SKILL.md') return PROGRESSIVE_ROUTER_ANCHORS[text] || null;
  return null;
}

function progressiveReferenceTarget(target, reference) {
  if (target === WORKFLOW_ENTRY) return path.join(WORKFLOW_REFERENCES, reference);
  if (target === 'skills/novel-assistant/SKILL.md') return ENTRY_RUNTIME;
  if (target === 'src/internal-skills/story/SKILL.md') return ROUTER_EDGE_CASES;
  throw new Error(`no progressive reference target for ${target}`);
}

function assertRouterEdgeReferenceRoutes(repoRootValue) {
  const layers = [
    {
      name: 'source',
      router: path.join(repoRootValue, 'src', 'internal-skills', 'story', 'SKILL.md'),
      reference: path.join(repoRootValue, 'src', 'internal-skills', 'story', 'references', 'router-edge-cases.md'),
    },
    {
      name: 'bundle',
      router: path.join(repoRootValue, 'skills', 'novel-assistant', 'references', 'internal-skills', 'story', 'SKILL.md'),
      reference: path.join(repoRootValue, 'skills', 'novel-assistant', 'references', 'internal-skills', 'story', 'references', 'router-edge-cases.md'),
    },
  ];

  for (const layer of layers) {
    const router = fs.readFileSync(layer.router, 'utf8');
    const reference = fs.readFileSync(layer.reference, 'utf8');
    const routeContract = parseStructuredContract(router, 'route-reference-contract');
    const edgeContract = parseStructuredContract(reference, 'edge-reference-contract');
    const routedEdgeIntents = new Set(routeContract.routes.filter(route => route.edge_intent).map(route => route.edge_intent));
    for (const route of edgeContract.routes) {
      const mapping = `| ${route.intent} | \`references/router-edge-cases.md\` |`;
      if (!router.includes(mapping)) throw new Error(`${layer.name} router edge mapping is missing: ${route.intent}`);
      if (!reference.includes(`## ${route.contract_anchor}`)) throw new Error(`${layer.name} router edge contract is missing: ${route.contract_anchor}`);
      if (!Array.isArray(route.trigger_samples) || route.trigger_samples.length === 0) throw new Error(`${layer.name} router edge triggers are missing: ${route.intent}`);
    }
    for (const intent of routedEdgeIntents) {
      if (!edgeContract.routes.some(route => route.intent === intent)) throw new Error(`${layer.name} route has no edge contract: ${intent}`);
    }
  }
}

function resolveRouteReferences(userIntent, layer) {
  const intent = String(userIntent || '').trim();
  if (!intent) throw new Error('--route-reference requires a non-empty user intent');
  const contracts = loadRouteReferenceContracts(repoRoot, layer);
  const selected = contracts.route.routes.find(item => (item.match_patterns || []).some(pattern => new RegExp(pattern, 'u').test(intent)));
  if (!selected) {
    return {
      status: 'pass',
      selectedLayer: layer,
      selectedRoute: contracts.route.fallback.selected_route,
      selectedReferences: contracts.route.fallback.references,
    };
  }

  if (!CASES.some(item => item.id === selected.smoke_case_id)) {
    throw new Error(`route reference case has no smoke case: ${selected.smoke_case_id}`);
  }
  if (selected.edge_intent && !contracts.edge.routes.some(item => item.intent === selected.edge_intent)) {
    throw new Error(`route reference case has no edge mapping: ${selected.edge_intent}`);
  }

  return {
    status: 'pass',
    selectedLayer: layer,
    selectedRoute: selected.selected_route,
    selectedReferences: selected.references,
  };
}

function loadRouteReferenceContracts(repoRootValue, layer) {
  const base = layer === 'bundle'
    ? path.join(repoRootValue, 'skills', 'novel-assistant', 'references', 'internal-skills')
    : path.join(repoRootValue, 'src', 'internal-skills');
  const router = fs.readFileSync(path.join(base, 'story', 'SKILL.md'), 'utf8');
  const edge = fs.readFileSync(path.join(base, 'story', 'references', 'router-edge-cases.md'), 'utf8');
  return {
    route: parseStructuredContract(router, 'route-reference-contract'),
    edge: parseStructuredContract(edge, 'edge-reference-contract'),
  };
}

function parseStructuredContract(text, name) {
  const match = String(text || '').match(new RegExp(`<!-- ${name}\\n([\\s\\S]*?)\\n${name} -->`));
  if (!match) throw new Error(`missing structured contract: ${name}`);
  return JSON.parse(match[1]);
}

function finding(caseId, layer, target, anchor, message) {
  return { caseId, layer, target, anchor, message };
}

function runCase(item) {
  const checks = item.checks.map(spec => runCheck(item.id, spec));
  const findings = checks.flatMap(result => result.findings);

  if (typeof item.run === 'function') {
    try {
      item.run();
    } catch (error) {
      findings.push(finding(item.id, 'runtime', 'runtime', '<execution>', error.message));
    }
  }

  return {
    id: item.id,
    label: item.label,
    status: findings.length ? 'fail' : 'pass',
    checks: checks.map(result => ({
      layer: result.layer,
      target: result.target,
      status: result.status,
      missing: result.findings.map(f => f.anchor),
    })),
    findings,
  };
}

function runGlobalCheck(item) {
  const checks = item.checks.map(spec => runCheck(item.id, spec));
  const findings = checks.flatMap(result => result.findings);
  if (typeof item.run === 'function') {
    try {
      item.run();
    } catch (error) {
      findings.push(finding(item.id, 'runtime', 'runtime', '<execution>', error.message));
    }
  }
  return {
    id: item.id,
    label: item.label,
    status: findings.length ? 'fail' : 'pass',
    checks: checks.map(result => ({
      layer: result.layer,
      target: result.target,
      status: result.status,
      missing: result.findings.map(f => f.anchor),
    })),
    findings,
  };
}

function runWorkflowTemplateCase(repoRootValue) {
  const sourceMachine = path.join(repoRootValue, 'scripts', 'workflow-state-machine.js');
  const bundleMachine = path.join(repoRootValue, 'skills', 'novel-assistant', 'scripts', 'workflow-state-machine.js');
  const source = runJson(process.execPath, [sourceMachine, 'templates', '--no-private-registry', '--json']);
  const bundle = runJson(process.execPath, [bundleMachine, 'templates', '--no-private-registry', '--json']);
  validateWorkflowTemplates('source', source);
  validateWorkflowTemplates('bundle', bundle);
  if (stableJson(source.templates) !== stableJson(bundle.templates)) {
    throw new Error('bundled workflow templates drift from source');
  }
  workflowTemplateSummary = {
    sourceCount: source.templates.length,
    bundleCount: bundle.templates.length,
    drift: false,
  };
  return workflowTemplateSummary;
}

function runLongformLifecycleMigrationCase(repoRootValue) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'na-lifecycle-migration-smoke-'));
  try {
    const scripts = [
      ['source', path.join(repoRootValue, 'scripts', 'workflow-legacy-migrate.js')],
      ['bundle', path.join(repoRootValue, 'skills', 'novel-assistant', 'scripts', 'workflow-legacy-migrate.js')],
    ];
    for (const [label, script] of scripts) {
      const project = path.join(tmp, label);
      writeLegacyLifecycleSmokeProject(project, true);
      const creativeBefore = creativeTreeHash(project);
      const preview = runJson(process.execPath, [script, '--project-root', project, '--source', 'oh-story', '--json']);
      assertLifecycleMigrationPreview(preview, label);
      assertCreativeTreeUnchanged(project, creativeBefore, `${label} preview`);
      if (fs.existsSync(path.join(project, '追踪', 'workflow', 'longform-lifecycle.json'))) {
        throw new Error(`${label} preview wrote a lifecycle index`);
      }

      const applied = runJson(process.execPath, [
        script, '--project-root', project, '--source', 'oh-story', '--write', '--workflow-id', 'wf-legacy-long-write', '--json',
      ]);
      if (applied.status !== 'lifecycle_migration_applied' || applied.creative_files_changed !== false
        || !applied.lifecycle_index_path || !applied.historical_snapshot_path) {
        throw new Error(`${label} confirm write returned invalid migration output`);
      }
      const indexPath = path.join(project, applied.lifecycle_index_path);
      if (!fs.existsSync(indexPath) || !fs.existsSync(path.join(project, applied.historical_snapshot_path))) {
        throw new Error(`${label} confirm write did not create lifecycle metadata and history`);
      }
      assertCreativeTreeUnchanged(project, creativeBefore, `${label} confirm write`);
    }

    for (const [label, script] of scripts) {
      const unknownProject = path.join(tmp, `${label}-unknown-source`);
      writeLegacyLifecycleSmokeProject(unknownProject, false);
      fs.rmSync(path.join(unknownProject, '设定'), { recursive: true, force: true });
      fs.rmSync(path.join(unknownProject, '大纲'), { recursive: true, force: true });
      const blocked = runJsonWithStatus(process.execPath, [
        script, '--project-root', unknownProject,
        '--source', 'oh-story', '--write', '--workflow-id', 'wf-legacy-long-write', '--json',
      ]);
      if (blocked.exitCode !== 2 || blocked.value.status !== 'blocked_lifecycle_migration_source_unknown') {
        throw new Error(`${label} unknown source was not blocked: ${blocked.value.status || blocked.stdout}`);
      }
      if (fs.existsSync(path.join(unknownProject, '追踪', 'workflow', 'longform-lifecycle.json'))) {
        throw new Error(`${label} unknown source wrote a lifecycle index`);
      }
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function runDetailOutlineQualityCase(repoRootValue) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'na-detail-outline-quality-smoke-'));
  try {
    const book = path.join(tmp, 'book');
    const outlineDir = path.join(book, '大纲');
    const workDir = path.join(book, '追踪', 'workflow', 'tasks', 'wf-smoke-detail-outline', 'work');
    fs.mkdirSync(outlineDir, { recursive: true });
    fs.mkdirSync(workDir, { recursive: true });

    const validRelative = '大纲/细纲_第001章.md';
    const validPath = path.join(book, validRelative);
    fs.writeFileSync(validPath, `# 第001章 旧账号水印
- 核心事件：平台逼林昭接下错误任务，林昭公开拒绝并保存调度截图。
- 目标情绪：压迫转为主动反击。
- 开篇钩子：后台突然出现一笔不属于她的罚单。
- 爽点：她当众投屏原始记录，让主管无法删证。
#### 情节安排
1. 主管以停单威胁逼她签字；林昭先截屏，再要求对方重复规则。
2. 主管试图拔线，她把手机投到大厅屏幕，围观骑手开始录音。
3. 罚单来源暴露为旧账号，林昭拿到继续追查的入口。
#### 质量触发
- 激活标签：人物线、悬念推进、爽点兑现
- 激活原因：主角第一次主动反击，并建立旧账号悬念。
#### 呈现与连续性
- 可见证据：调度截图、投屏记录、围观者录音。
- 前置承接：承接入职时发现的异常账号。
- 本章变化：林昭从被动申诉转为掌握证据并主动追查。
- 后续债务：旧账号的持有人尚未揭晓。
`);
    const validHash = crypto.createHash('sha256').update(fs.readFileSync(validPath)).digest('hex');
    const semanticRelative = '追踪/workflow/tasks/wf-smoke-detail-outline/work/detail-outline-semantic-review.json';
    fs.writeFileSync(path.join(book, semanticRelative), `${JSON.stringify({
      outline_path: validRelative,
      outline_sha256: validHash,
      reviewer: 'deterministic-smoke',
      findings: [],
    })}\n`);

    const underfilledRelative = '大纲/细纲_第002章.md';
    fs.writeFileSync(path.join(book, underfilledRelative), '# 第002章\n- 核心事件：主角回家。\n- 目标情绪：平静。\n');

    for (const script of [
      path.join(repoRootValue, 'scripts', 'detail-outline-quality-check.js'),
      path.join(repoRootValue, 'skills', 'novel-assistant', 'scripts', 'detail-outline-quality-check.js'),
    ]) {
      const accepted = runJsonWithStatus(process.execPath, [
        script,
        '--project-root', book,
        '--outline', validRelative,
        '--workflow-id', 'wf-smoke-detail-outline',
        '--semantic-review', semanticRelative,
        '--json',
      ]);
      const acceptedQuality = accepted.value && accepted.value.outputs && accepted.value.outputs.detail_outline_quality;
      if (accepted.exitCode !== 0 || !acceptedQuality || !/^pass/.test(acceptedQuality.status)
        || acceptedQuality.outline_sha256 !== validHash) {
        throw new Error(`valid detail outline did not pass: ${script}`);
      }

      const blocked = runJsonWithStatus(process.execPath, [
        script,
        '--project-root', book,
        '--outline', underfilledRelative,
        '--workflow-id', 'wf-smoke-detail-outline',
        '--json',
      ]);
      const blockedQuality = blocked.value && blocked.value.outputs && blocked.value.outputs.detail_outline_quality;
      if (blocked.exitCode !== 2 || !blockedQuality || blockedQuality.status !== 'outline_underfilled'
        || (blockedQuality.contract_projection || []).length || (blockedQuality.memory_projection || []).length) {
        throw new Error(`underfilled detail outline was not blocked: ${script}`);
      }
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function writeLegacyLifecycleSmokeProject(project, supportedSource) {
  const workflowId = 'wf-legacy-long-write';
  fs.mkdirSync(path.join(project, '设定'), { recursive: true });
  fs.mkdirSync(path.join(project, '大纲'), { recursive: true });
  fs.mkdirSync(path.join(project, '正文'), { recursive: true });
  fs.mkdirSync(path.join(project, '追踪', 'workflow', 'tasks', workflowId), { recursive: true });
  fs.writeFileSync(path.join(project, '设定', '定位.md'), '# 定位\n');
  fs.writeFileSync(path.join(project, '大纲', '总纲.md'), '# 总纲\n');
  fs.writeFileSync(path.join(project, '正文', '第001章.md'), '# 第一章\n\n既有正文不得被迁移改写。\n');
  if (supportedSource) {
    fs.writeFileSync(path.join(project, '.story-deployed'), '{"source_repository":"worldwonderer/oh-story-claudecode"}\n');
  }
  const task = {
    workflow_id: workflowId,
    workflow_type: 'long_write',
    status: 'running',
    task_dir: `追踪/workflow/tasks/${workflowId}`,
    scope: '第1-50章',
    migration_source: 'worldwonderer/oh-story-claudecode',
  };
  fs.writeFileSync(path.join(project, '追踪', 'workflow', 'tasks', workflowId, 'task.json'), `${JSON.stringify(task, null, 2)}\n`);
  fs.writeFileSync(path.join(project, '追踪', 'workflow', 'current-task.json'), `${JSON.stringify({
    schemaVersion: '1.0.0', workflow_id: workflowId, task_dir: task.task_dir, focused_at: new Date().toISOString(), state_version: 0,
  }, null, 2)}\n`);
}

function assertLifecycleMigrationPreview(preview, label) {
  const required = ['source', 'detected_assets', 'inferred_maturity', 'proposed_lifecycle_node', 'unresolved_conflicts', 'creative_files_changed'];
  if (preview.status !== 'migration_preview' || preview.source !== 'worldwonderer/oh-story-claudecode'
    || preview.creative_files_changed !== false || !required.every(key => Object.hasOwn(preview, key))
    || !Array.isArray(preview.detected_assets) || !preview.detected_assets.some(asset => asset.id === 'master_outline')) {
    throw new Error(`${label} preview status or fields are invalid`);
  }
}

function creativeTreeHash(project) {
  const files = [];
  for (const root of ['设定', '大纲', '正文']) {
    const absolute = path.join(project, root);
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(file);
        else if (entry.isFile()) files.push(file);
      }
    };
    walk(absolute);
  }
  const digest = crypto.createHash('sha256');
  for (const file of files.sort()) {
    digest.update(path.relative(project, file));
    digest.update('\0');
    digest.update(fs.readFileSync(file));
    digest.update('\0');
  }
  return digest.digest('hex');
}

function assertCreativeTreeUnchanged(project, before, phase) {
  if (creativeTreeHash(project) !== before) throw new Error(`${phase} changed creative file hashes`);
}

function validateWorkflowTemplates(label, result) {
  const requiredTypes = [
    'long_startup', 'short_startup', 'project_setup', 'long_write', 'short_write', 'review_repair', 'short_review', 'long_analyze',
    'download_import', 'deslop', 'setup_update', 'long_scan', 'short_scan', 'short_analyze', 'cover',
  ];
  const requiredResultFields = ['outputs', 'changed_files', 'evidence', 'verification_result', 'checkpoint_state', 'output_health_result'];
  const templates = new Map((result.templates || []).map((item) => [item.workflow_type, item]));
  if (result.templateCount !== 15 || templates.size !== 15) {
    throw new Error(`${label} expected fifteen first-class workflows, got ${templates.size}`);
  }
  for (const type of requiredTypes) {
    const template = templates.get(type);
    if (!template || !Array.isArray(template.stages) || template.stages.length === 0) {
      throw new Error(`${label} missing workflow template ${type}`);
    }
    if (!template.result_contract || template.result_contract.version !== 2) {
      throw new Error(`${label} ${type} missing v2 result contract`);
    }
    for (const field of requiredResultFields) {
      if (!template.result_contract.required_fields.includes(field)) {
        throw new Error(`${label} ${type} result contract missing ${field}`);
      }
    }
    const recovery = template.recovery || {};
    if (recovery.preserve_last_trusted_artifact !== true
      || !recovery.resume_from
      || !recovery.on_missing_result_packet
      || !recovery.on_output_failure) {
      throw new Error(`${label} ${type} missing recovery contract`);
    }
  }
}

function stableJson(value) {
  return JSON.stringify(value);
}

function assertDirectoryMirror(sourceRoot, bundleRoot) {
  const collect = (root, relative = '') => fs.readdirSync(path.join(root, relative), { withFileTypes: true })
    .flatMap((entry) => {
      const item = path.join(relative, entry.name);
      return entry.isDirectory() ? collect(root, item) : [item];
    })
    .sort();
  const sourceFiles = collect(sourceRoot);
  const bundleFiles = collect(bundleRoot);
  if (stableJson(sourceFiles) !== stableJson(bundleFiles)) throw new Error('bundled internal skill file list drift from source');
  for (const file of sourceFiles) {
    if (!fs.readFileSync(path.join(sourceRoot, file)).equals(fs.readFileSync(path.join(bundleRoot, file)))) {
      throw new Error(`bundled internal skill content drift from source: ${file}`);
    }
  }
}

function runStoryMemoryContextCase(repoRootValue) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'na-memory-smoke-'));
  try {
    const project = path.join(tmp, 'book');
    fs.mkdirSync(path.join(project, '追踪', 'memory'), { recursive: true });
    fs.mkdirSync(path.join(project, '设定'), { recursive: true });
    fs.writeFileSync(path.join(project, '设定', '演示.md'), [
      '# 演示设定',
      '- 演示角色在第1卷第001章出场。',
      '- 本文件只用于上下文装配冒烟测试。',
    ].join('\n'));
    fs.writeFileSync(path.join(project, '追踪', 'memory', 'active-cast.json'), `${JSON.stringify({
      range: '第1卷/第001章',
      presentCharacters: ['演示角色'],
      activeHooks: [],
      blockedReveals: [],
    }, null, 2)}\n`);
    fs.writeFileSync(path.join(project, '追踪', 'memory', 'lorebook.jsonl'), `${JSON.stringify({
      id: 'char.demo',
      type: 'character',
      title: '演示角色',
      aliases: ['演示角色'],
      triggers: ['演示角色'],
      scope: { book: 'current', volume: '第1卷', chapterRange: '第001章' },
      priority: 80,
      tokenBudget: 100,
      content: '演示角色当前只用于上下文装配冒烟测试。',
      constraints: [],
      sourceRefs: [{ path: '设定/演示.md', hash: 'sha256:demo', note: 'smoke' }],
      status: 'active',
      updatedAt: '2026-07-05T00:00:00Z',
    })}\n`);

    const script = path.join(repoRootValue, 'scripts', 'context-assembler.js');
    const result = runJson(process.execPath, [
      script,
      '--project-root', project,
      '--task', 'write_chapter',
      '--target', '第1卷/第001章',
      '--budget', '800',
      '--json',
    ]);
    if (result.status !== 'ok') throw new Error(`context assembler status ${result.status}`);
    if (!result.packetJson || !fs.existsSync(result.packetJson)) throw new Error('missing packet json');
    if (!result.packetMd || !fs.existsSync(result.packetMd)) throw new Error('missing packet md');

    const packet = fs.readFileSync(result.packetJson, 'utf8');
    if (packet.includes('private-internal-skills')) {
      throw new Error('public memory packet leaked private module path');
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function runTask11BehaviorContractCase(repoRootValue) {
  const script = path.join(repoRootValue, 'scripts', 'task11-behavior-validator.js');
  const fixture = path.join(repoRootValue, 'tests', 'fixtures', 'task11-behavior-contract.json');
  const result = runJson(process.execPath, [script, '--fixture', fixture, '--json']);
  const audit = runJson(process.execPath, [script, '--audit-repo', '--repo-root', repoRootValue, '--json']);
  if (result.status !== 'pass' || result.caseCount !== 6) {
    throw new Error(`Task 11 behavior validator returned ${result.status} with ${result.caseCount} cases`);
  }
  if (audit.status !== 'pass' || audit.checkCount < 8 || audit.findings.length !== 0) {
    throw new Error(`Task 11 repository audit failed with ${audit.findings.length} findings`);
  }

  const cases = new Map(result.results.map(item => [item.caseId, item.result]));
  const bare = cases.get('bare_invocation_docks');
  const underfilled = cases.get('outline_underfilled_blocks');
  const batch = cases.get('fourth_chapter_is_deferred');
  const card = cases.get('single_genre_card_is_sanitized');
  const advisory = cases.get('advisory_does_not_rewrite');
  const antiPandering = cases.get('anti_pandering_preserves_story');
  if (!bare || bare.decision !== 'dock_preconditions' || bare.proseCandidates.length !== 0) {
    throw new Error('bare long-write invocation did not dock before prose generation');
  }
  if (!underfilled || underfilled.blockingReason !== 'outline_underfilled'
    || underfilled.proseCandidates.length !== 0) {
    throw new Error('outline_underfilled did not suppress prose candidates');
  }
  if (!batch || stableJson(batch.scheduledChapters) !== '[1,2,3]'
    || stableJson(batch.deferredChapters) !== '[4]'
    || batch.writerPackets.some(packet => packet.chapter === 4)) {
    throw new Error('fourth chapter was not deferred');
  }
  const writerPacket = card && card.writerPackets[0];
  const serializedPacket = stableJson(writerPacket || {});
  if (!writerPacket || stableJson(writerPacket.assemblyOrder) !== '["chapter_contract","genre_prose_card"]'
    || writerPacket.genreProseCards.length !== 1
    || /sourceSample|complianceSelfReview|metadata|must-not-enter/.test(serializedPacket)) {
    throw new Error('genre prose card assembly leaked metadata or violated ordering');
  }
  if (!advisory || advisory.blocking || advisory.automaticRewriteActions.length !== 0) {
    throw new Error('advisory detector evidence became blocking or automatic rewrite');
  }
  if (!antiPandering || stableJson(antiPandering.facts) !== '["主角已经交出钥匙","守门人亲眼见证"]'
    || stableJson(antiPandering.structure) !== '["对质","交出钥匙","守门人放行"]') {
    throw new Error('anti-pandering changed story facts or structure');
  }
}

function runJson(command, commandArgs) {
  const stdout = childProcess.execFileSync(command, commandArgs, { encoding: 'utf8' });
  return JSON.parse(stdout);
}

function runJsonWithStatus(command, commandArgs) {
  const result = childProcess.spawnSync(command, commandArgs, { encoding: 'utf8' });
  if (result.error) throw result.error;
  let value;
  try {
    value = JSON.parse(result.stdout || '');
  } catch (error) {
    throw new Error(`migration command did not return JSON: ${error.message}`);
  }
  return { exitCode: result.status, value, stdout: result.stdout };
}

function runProseQualityCalibrationCase(repoRootValue) {
  const script = path.join(repoRootValue, 'scripts', 'prose-quality-benchmark.js');
  const benchmark = runJson(process.execPath, [script, '--json']);
  const packet = runJson(process.execPath, [script, '--blind-packet', '--json']);
  const baselinePath = path.join(repoRootValue, 'reports', 'verification', 'prose-quality-baseline.json');
  const protocolPath = path.join(repoRootValue, 'src', 'internal-skills', 'story-review', 'references', 'blind-reader-protocol.md');
  const baseline = readJsonFileForSmoke(baselinePath, 'prose-quality baseline');

  validateProseQualityBenchmark(benchmark, 'live benchmark');
  validateProseQualityBenchmark(baseline, 'baseline');
  if (stableJson(bindingProseQualityIdentity(benchmark.sourceIdentity)) !== stableJson(bindingProseQualityIdentity(baseline.sourceIdentity))) {
    throw new Error('prose-quality baseline is stale for current benchmark inputs');
  }
  validateProseQualityPacket(packet);
  validateProseQualityFixtures(path.join(repoRootValue, 'tests', 'fixtures', 'prose-quality'));
  validateBlindReaderProtocol(fs.readFileSync(protocolPath, 'utf8'));

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'na-prose-quality-smoke-'));
  try {
    const verdictPath = path.join(tmp, 'verdict.json');
    fs.writeFileSync(verdictPath, `${JSON.stringify({
      schemaVersion: '1.0.0',
      packetId: packet.packetId,
      packetDigest: packet.packetDigest,
      verdicts: packet.items.map(item => ({ id: item.id, verdict: 'retain', evidence: `Smoke review for ${item.id}.` })),
    }, null, 2)}\n`);
    const locked = runJson(process.execPath, [script, '--lock-verdict', verdictPath, '--json']);
    if (locked.artifactType !== 'blind-verdict-lock' || !/^sha256:[a-f0-9]{64}$/.test(locked.lockedVerdictHash || '')) {
      throw new Error('blind verdict lock artifact schema is invalid');
    }
    const lockPath = path.join(tmp, 'lock.json');
    fs.writeFileSync(lockPath, `${JSON.stringify(locked, null, 2)}\n`);
    const revealed = runJson(process.execPath, [script, '--reveal', lockPath, '--json']);
    if (revealed.artifactType !== 'blind-verdict-reveal' || revealed.lockedVerdictHash !== locked.lockedVerdictHash) {
      throw new Error('blind verdict reveal artifact is invalid');
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function bindingProseQualityIdentity(identity) {
  return {
    identityVersion: identity.identityVersion,
    benchmarkSourceHash: identity.benchmarkSourceHash,
    corpusContentHash: identity.corpusContentHash,
    detectorSourceHashes: identity.detectorSourceHashes,
  };
}

function validateProseQualityBenchmark(result, label) {
  if (!result || result.schemaVersion !== '2.0.0') throw new Error(`${label} has an unsupported schema`);
  const matrix = result.counts && result.counts.confusionMatrix;
  const expectedMatrixKeys = ['truePositive', 'falsePositive', 'trueNegative', 'falseNegative'];
  if (!matrix || !expectedMatrixKeys.every(key => Number.isInteger(matrix[key]) && matrix[key] >= 0)) {
    throw new Error(`${label} has an invalid confusion matrix`);
  }
  if (expectedMatrixKeys.reduce((sum, key) => sum + matrix[key], 0) !== result.corpus.recordCount) {
    throw new Error(`${label} confusion matrix does not match corpus record count`);
  }
  const metricKeys = ['precision', 'recall', 'falsePositiveRate', 'falseNegativeRate'];
  if (!result.metrics || !metricKeys.every(key => result.metrics[key] && result.metrics[key].status === 'available'
    && typeof result.metrics[key].value === 'number')) {
    throw new Error(`${label} has unavailable or invalid metrics`);
  }
  if (!result.aggregationPolicy || result.aggregationPolicy.version !== 'severity-any-v1'
    || stableJson(result.aggregationPolicy.includedSeverities) !== stableJson(['advisory', 'blocking'])) {
    throw new Error(`${label} has an invalid aggregation policy`);
  }
  const identity = result.sourceIdentity || {};
  if (!/^sha256:[a-f0-9]{64}$/.test(identity.benchmarkSourceHash || '')
    || !/^sha256:[a-f0-9]{64}$/.test(identity.corpusContentHash || '')
    || !identity.detectorSourceHashes || !identity.sourceCommit || !identity.sourceTree) {
    throw new Error(`${label} has an invalid source identity`);
  }
  for (const severity of ['advisory', 'blocking']) {
    const layer = result.counts.bySeverity && result.counts.bySeverity[severity];
    if (!layer || !Number.isInteger(layer.findingCount) || !Number.isInteger(layer.recordCount)) {
      throw new Error(`${label} is missing ${severity} layered counts`);
    }
  }
}

function validateProseQualityPacket(packet) {
  if (!packet || packet.packetVersion !== 'v2' || !/^blind-packet-v2-[a-f0-9]{16}$/.test(packet.packetId || '')
    || !/^sha256:[a-f0-9]{64}$/.test(packet.packetDigest || '') || !Array.isArray(packet.items) || packet.items.length === 0) {
    throw new Error('blind packet schema is invalid');
  }
  if (!packet.items.every(item => typeof item.id === 'string' && item.id && typeof item.text === 'string' && item.text)) {
    throw new Error('blind packet items are invalid');
  }
  if (/"(?:expectedDetection|model|generator|revision|provenance|category|claimStatus)"\s*:/i.test(JSON.stringify(packet))) {
    throw new Error('blind packet leaked provenance or labels');
  }
}

function validateProseQualityFixtures(dir) {
  const specs = [
    ['accepted.jsonl', false],
    ['rejected.jsonl', true],
    ['boundary.jsonl', null],
  ];
  const ids = new Set();
  let positive = 0;
  let negative = 0;
  for (const [name, expected] of specs) {
    const records = fs.readFileSync(path.join(dir, name), 'utf8').split(/\r?\n/).filter(line => line.trim()).map(JSON.parse);
    if (records.length === 0) throw new Error(`${name} is empty`);
    for (const record of records) {
      if (!record.id || ids.has(record.id) || !record.provenance || record.provenance.claimStatus !== 'self-declared') {
        throw new Error(`${name} has an invalid record schema`);
      }
      if (expected !== null && record.expectedDetection !== expected) throw new Error(`${name} violates expectedDetection semantics`);
      if (expected === null && (!['accepted', 'rejected'].includes(record.boundaryDisposition)
        || typeof record.boundaryReason !== 'string' || !record.boundaryReason.trim())) {
        throw new Error('boundary.jsonl has an invalid boundary schema');
      }
      ids.add(record.id);
      if (record.expectedDetection) positive += 1;
      else negative += 1;
    }
  }
  if (!positive || !negative) throw new Error('prose-quality fixtures lack truth-class support');
}

function validateBlindReaderProtocol(protocol) {
  const required = ['--lock-verdict', '--reveal', 'lockedVerdictHash', 'self-declared', 'sourceIdentity'];
  if (!required.every(anchor => protocol.includes(anchor))) {
    throw new Error('blind-reader protocol does not document verifiable calibration artifacts');
  }
}

function readJsonFileForSmoke(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read ${label}: ${error.message}`);
  }
}

function printHuman(result) {
  console.log(`production smoke matrix: ${result.status}`);
  for (const item of result.globalChecks) {
    console.log(`- ${item.id}: ${item.status} | ${item.label}`);
    for (const findingItem of item.findings) {
      console.log(`  - ${findingItem.layer} ${findingItem.target}: missing ${findingItem.anchor}`);
    }
  }
  for (const item of result.cases) {
    console.log(`- ${item.id}: ${item.status} | ${item.label}`);
    for (const findingItem of item.findings) {
      console.log(`  - ${findingItem.layer} ${findingItem.target}: missing ${findingItem.anchor}`);
    }
  }
}

if (routeReferenceIntent) {
  const resolution = resolveRouteReferences(routeReferenceIntent, routeReferenceLayer);
  process.stdout.write(jsonOutput ? `${JSON.stringify(resolution)}\n` : `${JSON.stringify(resolution, null, 2)}\n`);
  process.exit(0);
}

const globalChecks = GLOBAL_CHECKS.map(runGlobalCheck);
const cases = CASES.map(runCase);
const findings = [
  ...globalChecks.flatMap(item => item.findings),
  ...cases.flatMap(item => item.findings),
];
const result = {
  schemaVersion: '1.0.0',
  status: findings.length ? 'fail' : 'pass',
  generatedAt: new Date().toISOString(),
  repoRoot,
  globalChecks,
  workflowTemplateCount: workflowTemplateSummary.sourceCount,
  workflowBundleTemplateCount: workflowTemplateSummary.bundleCount,
  workflowTemplateDrift: workflowTemplateSummary.drift,
  caseCount: cases.length,
  cases,
  findings,
};

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printHuman(result);
}

process.exit(result.status === 'pass' ? 0 : 2);
